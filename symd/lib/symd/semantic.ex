defmodule Symd.Semantic do
  @moduledoc """
  Answers the semantic questions — symbols, definition, references — in terms
  of files, names, and 1-based locations, hiding LSP's method shapes and
  UTF-16 coordinates.

  Name queries fan out to every configured LSP and come back grouped per
  matching symbol, up to a small cap, so the common case is answered in one
  call and heavy ambiguity returns candidates to narrow with a qualified name
  or an exact location. Locations are authoritative; names are search terms.
  Files are read from disk for every query: agents edit files between
  queries, and a confidently stale answer is worse than no tool at all.
  """

  alias Symd.{Position, Workspace}
  alias Symd.Lsp.Uri

  @max_reference_matches 5
  @max_candidates 20

  @doc "All symbols a file declares, flattened, in file order."
  def symbols(%Workspace{} = workspace, path) do
    with {:ok, lsp} <- lsp_for(workspace, path),
         {:ok, content} <- workspace.sync.(lsp, path),
         {:ok, result} <-
           workspace.request.(lsp, "textDocument/documentSymbol", %{
             "textDocument" => %{"uri" => Uri.from_path(path)}
           }) do
      symbols =
        result
        |> document_symbols(path, lines(content))
        |> Enum.sort_by(&{&1["line"], &1["column"]})

      {:ok, %{"symbols" => symbols}}
    end
  end

  @doc "Definition sites, from an exact location or from a (possibly dotted) name."
  def definition(%Workspace{} = workspace, %{path: _, line: _, column: _} = at) do
    with {:ok, lsp, params} <- position_params(workspace, at),
         {:ok, result} <- workspace.request.(lsp, "textDocument/definition", params) do
      {:ok, %{"definitions" => result |> locations() |> resolve_locations()}}
    end
  end

  def definition(%Workspace{} = workspace, name) when is_binary(name) do
    with {:ok, matches} <- find_symbols(workspace, name) do
      {:ok, %{"definitions" => Enum.map(matches, fn {_lsp, symbol} -> symbol end)}}
    end
  end

  @doc """
  Reference sites, from an exact location or from a name. A name that matches
  more symbols than the cap comes back as `candidates` instead of `matches`,
  so the caller can narrow rather than wait for a pile of lookups.
  """
  def references(%Workspace{} = workspace, %{path: _, line: _, column: _} = at) do
    with {:ok, lsp, params} <- position_params(workspace, at),
         {:ok, result} <-
           workspace.request.(
             lsp,
             "textDocument/references",
             Map.put(params, "context", %{"includeDeclaration" => true})
           ) do
      {:ok, %{"matches" => [%{"refs" => result |> locations() |> resolve_locations()}]}}
    end
  end

  def references(%Workspace{} = workspace, name) when is_binary(name) do
    with {:ok, matches} <- find_symbols(workspace, name) do
      if length(matches) > @max_reference_matches do
        candidates = matches |> Enum.map(&elem(&1, 1)) |> Enum.take(@max_candidates)
        {:ok, %{"candidates" => candidates}}
      else
        with {:ok, groups} <- map_ok(matches, &match_references(workspace, &1)) do
          {:ok, %{"matches" => groups}}
        end
      end
    end
  end

  # Name resolution ---------------------------------------------------------

  defp find_symbols(workspace, full_name) do
    query = parse_symbol_name(full_name)

    with {:ok, answers} <- fan_out(workspace, query.base) do
      matches =
        answers
        |> Enum.filter(fn {_lsp, info} -> exact?(info, query) end)
        |> Enum.flat_map(fn {lsp, info} ->
          case workspace_symbol(info) do
            nil -> []
            symbol -> [{lsp, symbol}]
          end
        end)
        |> Enum.uniq_by(fn {_lsp, symbol} -> Map.take(symbol, ["path", "line", "column"]) end)

      case matches do
        [] -> {:error, {:symbol_not_found, full_name, similar(answers, query.base)}}
        matches -> {:ok, matches}
      end
    end
  end

  # Ask every configured server; a broken server must not hide another's
  # answer, but when nobody can answer, the caller gets the real error.
  defp fan_out(%Workspace{lsps: lsps} = workspace, query) do
    results =
      Enum.map(lsps, fn lsp ->
        seed(workspace, lsp)
        settle(workspace, lsp)
        {lsp, workspace.request.(lsp, "workspace/symbol", %{"query" => query})}
      end)

    answers = for {lsp, {:ok, infos}} <- results, is_list(infos), info <- infos, do: {lsp, info}

    # Name the failing server: with several configured, "a language server
    # exited" without saying which one sends the reader to the wrong place.
    errors = for {lsp, {:error, reason}} <- results, do: {:lsp_failed, lsp.name, reason}

    case {answers, errors} do
      {[], [reason | _rest]} -> {:error, reason}
      _any -> {:ok, answers}
    end
  end

  # Some servers (tsserver among them) can't answer workspace/symbol until a
  # file of the project is open — and tsserver scopes the search to the
  # project of the file it most recently saw. A root-level file is usually
  # build configuration (vite.config.ts) belonging to a side project, so
  # prefer a file below the root, source directories first, and fall back to
  # a root-level file only when nothing deeper exists. Syncing is a cheap
  # no-op on every query after the first.
  defp seed(workspace, lsp) do
    case seed_file([workspace.root], lsp.extensions, 0, nil) do
      nil -> :ok
      path -> workspace.sync.(lsp, path)
    end
  end

  defp settle(%Workspace{settle: nil}, _lsp), do: :ok
  defp settle(%Workspace{settle: settle}, lsp), do: settle.(lsp)

  @skipped_directories ~w(node_modules deps _build target dist build out vendor)
  @preferred_directories %{"src" => 0, "lib" => 1, "apps" => 2}

  defp seed_file([], _extensions, _visited, fallback), do: fallback
  defp seed_file(_queue, _extensions, visited, fallback) when visited > 512, do: fallback

  defp seed_file([directory | queue], extensions, visited, fallback) do
    entries =
      case File.ls(directory) do
        {:ok, entries} -> Enum.sort(entries)
        {:error, _reason} -> []
      end

    found =
      Enum.find_value(entries, fn entry ->
        path = Path.join(directory, entry)

        (String.downcase(Path.extname(entry)) in extensions and File.regular?(path)) && path
      end)

    if found != nil and visited > 0 do
      found
    else
      subdirectories =
        for entry <- entries,
            not String.starts_with?(entry, "."),
            entry not in @skipped_directories,
            path = Path.join(directory, entry),
            File.dir?(path),
            do: path

      subdirectories =
        Enum.sort_by(subdirectories, fn path ->
          {Map.get(@preferred_directories, Path.basename(path), 9), path}
        end)

      seed_file(queue ++ subdirectories, extensions, visited + 1, fallback || found)
    end
  end

  defp split_name(full_name) do
    case String.split(full_name, ".") do
      [single] -> {nil, single}
      parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
    end
  end

  # Servers disagree about what goes into a workspace symbol's name: tsserver
  # reports a bare identifier with the parent in containerName, while dexter
  # reports "Symd.Servers.stop_root/1" with no container at all. Queries and
  # candidates are both parsed into container/base/arity, so the same query
  # works against either convention — and a suggestion can be pasted back in.
  defp exact?(%{"name" => name} = info, query) do
    candidate = parse_symbol_name(name, info["containerName"])

    candidate.base == query.base and
      container_matches?(candidate.container, query.container) and
      arity_matches?(candidate.arity, query.arity)
  end

  defp exact?(_info, _query), do: false

  defp parse_symbol_name(full, outer \\ nil) do
    {bare, arity} =
      case Regex.run(~r{\A(.+)/(\d+)\z}, full) do
        [_all, bare, arity] -> {bare, String.to_integer(arity)}
        nil -> {full, nil}
      end

    {container, base} = split_name(bare)
    %{container: join_container(outer, container), base: base, arity: arity}
  end

  # dexter puts the module path in containerName AND in the name; joining
  # blindly would yield Symd.Servers.Symd.Servers.stop_root.
  defp join_container(outer, inner) do
    cond do
      outer in [nil, ""] -> presence(inner)
      inner in [nil, ""] -> presence(outer)
      inner == outer or String.starts_with?(inner, outer <> ".") -> inner
      true -> outer <> "." <> inner
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  # A dotted query narrows by container suffix: Servers.stop_root matches a
  # candidate whose container is Symd.Servers.
  defp container_matches?(_candidate, nil), do: true
  defp container_matches?(nil, _wanted), do: false

  defp container_matches?(candidate, wanted),
    do: candidate == wanted or String.ends_with?(candidate, "." <> wanted)

  defp arity_matches?(_candidate, nil), do: true
  defp arity_matches?(candidate, arity), do: candidate == arity

  defp workspace_symbol(%{"name" => name, "kind" => kind} = info) do
    with %{"uri" => uri, "range" => %{"start" => start}} <- info["location"],
         {:ok, path} <- Uri.to_path(uri) do
      # Servers anchor these ranges at the declaration's first keyword;
      # re-anchor on the identifier (the parsed base — a qualified name
      # never appears verbatim in the source line) so def and symbols agree.
      text = line_text(path, start["line"])
      anchor = parse_symbol_name(name).base
      column = Position.find_name(text, anchor, Position.column(text, start["character"]))

      prune(%{
        "name" => name,
        "kind" => kind_name(kind),
        "container" => displayed_container(name, info["containerName"]),
        "path" => path,
        "line" => start["line"] + 1,
        "column" => column
      })
    else
      # Without a resolvable location there is nothing to point an agent at.
      _other -> nil
    end
  end

  # A container that is already spelled out inside the name (dexter) would
  # print doubled; keep it only when it adds information (tsserver).
  defp displayed_container(name, container) do
    if is_binary(container) and
         (name == container or String.starts_with?(name, container <> ".")),
       do: nil,
       else: container
  end

  defp similar(answers, base) do
    answers
    |> Enum.map(fn {_lsp, info} -> info["name"] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == base))
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp match_references(workspace, {lsp, symbol}) do
    with {:ok, content} <- workspace.sync.(lsp, symbol["path"]) do
      # The symbol's range may start at a keyword; references wants the
      # cursor on the identifier itself.
      text = Enum.at(lines(content), symbol["line"] - 1) || ""
      column = Position.find_name(text, parse_symbol_name(symbol["name"]).base, symbol["column"])

      params = %{
        "textDocument" => %{"uri" => Uri.from_path(symbol["path"])},
        "position" => %{
          "line" => symbol["line"] - 1,
          "character" => Position.utf16_offset(text, column)
        },
        "context" => %{"includeDeclaration" => true}
      }

      with {:ok, result} <- workspace.request.(lsp, "textDocument/references", params) do
        {:ok, %{"symbol" => symbol, "refs" => result |> locations() |> resolve_locations()}}
      end
    end
  end

  # Locations ---------------------------------------------------------------

  defp position_params(workspace, %{path: path, line: line, column: column}) do
    with {:ok, lsp} <- lsp_for(workspace, path),
         {:ok, content} <- workspace.sync.(lsp, path) do
      # Opening the file may have kicked off a project load; def and refs
      # answered during one are confidently incomplete.
      settle(workspace, lsp)
      text = Enum.at(lines(content), line - 1) || ""

      {:ok, lsp,
       %{
         "textDocument" => %{"uri" => Uri.from_path(path)},
         "position" => %{"line" => line - 1, "character" => Position.utf16_offset(text, column)}
       }}
    end
  end

  defp lsp_for(%Workspace{lsps: lsps}, path) do
    extension = path |> Path.extname() |> String.downcase()

    case Enum.find(lsps, fn lsp -> extension in lsp.extensions end) do
      nil -> {:error, {:no_lsp_for_path, path, Enum.flat_map(lsps, & &1.extensions)}}
      lsp -> {:ok, lsp}
    end
  end

  # definition may answer with null, one Location, Locations, or LocationLinks.
  defp locations(nil), do: []
  defp locations(%{"uri" => _uri} = location), do: location(location)
  defp locations(list) when is_list(list), do: Enum.flat_map(list, &location/1)
  defp locations(_other), do: []

  defp location(%{"uri" => uri, "range" => %{"start" => start}}), do: [{uri, start}]

  defp location(%{"targetUri" => uri} = link) do
    case get_in(link, ["targetSelectionRange", "start"]) || get_in(link, ["targetRange", "start"]) do
      nil -> []
      start -> [{uri, start}]
    end
  end

  defp location(_other), do: []

  defp resolve_locations(pairs) do
    {entries, _cache} =
      Enum.map_reduce(pairs, %{}, fn {uri, %{"line" => line, "character" => character}}, cache ->
        case Uri.to_path(uri) do
          {:ok, path} ->
            {file_lines, cache} = cached_lines(cache, path)
            text = Enum.at(file_lines, line) || ""

            {%{"path" => path, "line" => line + 1, "column" => Position.column(text, character)},
             cache}

          :error ->
            {nil, cache}
        end
      end)

    entries
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["path"], &1["line"], &1["column"]})
  end

  defp cached_lines(cache, path) do
    case cache do
      %{^path => file_lines} ->
        {file_lines, cache}

      _missing ->
        file_lines =
          case File.read(path) do
            {:ok, content} -> lines(content)
            {:error, _reason} -> []
          end

        {file_lines, Map.put(cache, path, file_lines)}
    end
  end

  defp line_text(path, line) do
    case File.read(path) do
      {:ok, content} -> Enum.at(lines(content), line) || ""
      {:error, _reason} -> ""
    end
  end

  defp lines(content), do: String.split(content, "\n")

  # Symbol shaping ----------------------------------------------------------

  defp document_symbols(nil, _path, _lines), do: []

  defp document_symbols([%{"selectionRange" => _} | _rest] = nested, path, lines),
    do: flatten(nested, nil, path, lines)

  defp document_symbols(flat, path, lines) when is_list(flat) do
    for %{"name" => name, "kind" => kind} = info <- flat,
        start = get_in(info, ["location", "range", "start"]),
        start != nil do
      entry(name, kind, info["containerName"], path, start, lines)
    end
  end

  defp document_symbols(_other, _path, _lines), do: []

  defp flatten(nested, container, path, lines) do
    Enum.flat_map(nested, fn
      %{"name" => name, "kind" => kind, "selectionRange" => %{"start" => start}} = node ->
        [
          entry(name, kind, container, path, start, lines)
          | flatten(Map.get(node, "children") || [], name, path, lines)
        ]

      _other ->
        []
    end)
  end

  defp entry(name, kind, container, path, %{"line" => line, "character" => character}, lines) do
    text = Enum.at(lines, line) || ""

    prune(%{
      "name" => name,
      "kind" => kind_name(kind),
      "container" => container,
      "path" => path,
      "line" => line + 1,
      "column" => Position.column(text, character)
    })
  end

  @kinds %{
    1 => "file",
    2 => "module",
    3 => "namespace",
    4 => "package",
    5 => "class",
    6 => "method",
    7 => "property",
    8 => "field",
    9 => "constructor",
    10 => "enum",
    11 => "interface",
    12 => "function",
    13 => "variable",
    14 => "constant",
    15 => "string",
    16 => "number",
    17 => "boolean",
    18 => "array",
    19 => "object",
    20 => "key",
    21 => "null",
    22 => "enum-member",
    23 => "struct",
    24 => "event",
    25 => "operator",
    26 => "type-parameter"
  }

  defp kind_name(kind), do: Map.get(@kinds, kind, "symbol")

  defp prune(map),
    do: for({key, value} <- map, value not in [nil, ""], into: %{}, do: {key, value})

  defp map_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
