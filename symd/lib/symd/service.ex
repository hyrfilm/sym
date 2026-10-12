defmodule Symd.Service do
  @moduledoc """
  Connects client requests to a workspace's semantic operations.

  Every semantic request carries the caller's working directory, and
  `Symd.Workspaces` turns that into the workspace the query runs against —
  one daemon serves any number of projects. Requests are validated strictly:
  a misspelled or extra field is an error, not something to guess about, and
  every reply is an envelope the CLI can print without knowing the
  operation. Control results are tagged so the transport can act on them.
  """

  alias Symd.{Semantic, Workspaces}

  @protocol 4

  @doc """
  Decodes a request and passes it to `handle/2`. Bad JSON becomes an error
  reply so it only spoils that request. Transport owns framing and size
  limits; this function deals with the contents of a request.

  `deps` exists for tests: `:fetch` resolves a cwd to a workspace and
  `:list` names the known workspaces. Both default to `Symd.Workspaces`.
  """
  def request(json, deps \\ []) do
    case JSON.decode(json) do
      {:ok, request} -> handle(request, deps)
      {:error, _reason} -> error("invalid_request", "expected a JSON request")
    end
  end

  @doc """
  Handles semantic and daemon-control messages in our small public protocol.
  Missing and extra fields are rejected so a misspelled option can't silently
  change what a request does. Locations are 1-based `line`/`column` in
  codepoints; the semantic layer owns the LSP coordinate conversion.
  """
  def handle(request, deps \\ [])

  def handle(%{"op" => "symbols", "path" => path, "cwd" => cwd} = request, deps)
      when map_size(request) == 3 and is_binary(path) and byte_size(path) > 0 do
    semantic(deps, cwd, &Semantic.symbols(&1, path))
  end

  def handle(%{"op" => op, "name" => name, "cwd" => cwd} = request, deps)
      when op in ["def", "refs"] and map_size(request) == 3 and is_binary(name) and
             byte_size(name) > 0 do
    case op do
      "def" -> semantic(deps, cwd, &Semantic.definition(&1, name))
      "refs" -> semantic(deps, cwd, &Semantic.references(&1, name))
    end
  end

  def handle(
        %{"op" => op, "path" => path, "line" => line, "column" => column, "cwd" => cwd} =
          request,
        deps
      )
      when op in ["def", "refs"] and map_size(request) == 5 and is_binary(path) and
             byte_size(path) > 0 and is_integer(line) and line >= 1 and is_integer(column) and
             column >= 1 do
    at = %{path: path, line: line, column: column}

    case op do
      "def" -> semantic(deps, cwd, &Semantic.definition(&1, at))
      "refs" -> semantic(deps, cwd, &Semantic.references(&1, at))
    end
  end

  # Management messages use the same socket as semantic requests. The
  # protocol number lets the launcher verify that it found a compatible symd.
  def handle(%{"op" => "status"} = request, deps) when map_size(request) == 1 do
    list = Keyword.get(deps, :list, &Workspaces.list/0)

    {:daemon, :status,
     %{
       "ok" => true,
       "result" => %{
         "service" => "symd",
         "protocol" => @protocol,
         "state" => "running",
         "pid" => System.pid(),
         "workspaces" => list.()
       }
     }}
  end

  def handle(%{"op" => "stop"} = request, _deps) when map_size(request) == 1 do
    # A stop is an explicit control result. Transport sends the acknowledgement
    # before closing the listener, so the executable can unlink its own socket.
    {:daemon, :stop,
     %{
       "ok" => true,
       "result" => %{"service" => "symd", "protocol" => @protocol, "state" => "stopping"}
     }}
  end

  def handle(_request, _deps),
    do:
      error(
        "invalid_request",
        "expected symbols with path, or def/refs with name or with path+line+column " <>
          "(each with the caller's cwd), or status, or stop"
      )

  # The caller's working directory picks the workspace, per request, so one
  # daemon answers for every project and a config edit is seen immediately.
  defp semantic(deps, cwd, operation) do
    if is_binary(cwd) and Path.type(cwd) == :absolute do
      fetch = Keyword.get(deps, :fetch, &Workspaces.fetch/1)

      case fetch.(cwd) do
        {:ok, workspace} -> reply(operation.(workspace))
        {:error, reason} -> reply({:error, reason})
      end
    else
      error("invalid_request", "cwd must be an absolute path")
    end
  end

  defp reply({:ok, result}), do: %{"ok" => true, "result" => result}
  defp reply({:error, reason}), do: error(code(reason), reason)

  # Stable codes for clients; the message is for the person reading it.
  defp code({:lsp_failed, _name, reason}), do: code(reason)
  defp code({:no_workspace, _cwd}), do: "no_workspace"
  defp code({:no_config, _root, _global}), do: "no_config"
  defp code({:config_unreadable, _path, _posix}), do: "invalid_config"
  defp code({:invalid_config, _path, _detail}), do: "invalid_config"
  defp code({:no_lsp_for_path, _path, _extensions}), do: "unsupported_file"
  defp code({:no_lsp_for_workspace, _root, _extensions}), do: "unsupported_workspace"
  defp code({:symbol_not_found, _name, _similar}), do: "symbol_not_found"
  defp code({:no_symbol_at, _path, _line, _column}), do: "no_symbol_at"
  defp code({:file_read, _path, _reason}), do: "file_unreadable"
  defp code({:executable_not_found, _command}), do: "lsp_unavailable"
  defp code({:server_exited, _status}), do: "lsp_unavailable"
  defp code({:server_start_failed, _detail}), do: "lsp_unavailable"
  defp code({:initialize_failed, _detail}), do: "lsp_unavailable"
  defp code({:lsp_client_down, _reason}), do: "lsp_unavailable"
  defp code(:lsp_timeout), do: "lsp_timeout"
  defp code({:lsp_error, _code, _message}), do: "lsp_request_failed"
  defp code({:invalid_server_message, _reason}), do: "lsp_request_failed"
  defp code(_other), do: "internal_error"

  @doc """
  Builds the error half of a reply. Clients can use the stable `code`, while
  the message gives a person enough context to understand the failure.
  """
  def error(code, reason) do
    %{"ok" => false, "error" => %{"code" => code, "message" => message(reason)}}
  end

  @doc """
  Explains failures returned by the semantic layer or transport. The
  executable uses the same messages for startup errors.
  """
  def message({:lsp_failed, name, reason}), do: "[#{name}] #{message(reason)}"

  def message({:no_workspace, cwd}),
    do: "no workspace found from #{cwd}: no sym.toml or .git here or in any parent directory"

  def message({:no_config, root, global}),
    do: "#{root} has no sym.toml, and there is no global config at #{global}"

  def message({:config_unreadable, path, posix}), do: "cannot read #{path}: #{message(posix)}"
  def message({:invalid_config, path, detail}), do: "#{path}: #{detail}"

  def message({:no_lsp_for_path, path, []}),
    do: "no LSPs are configured; add an [lsp.<name>] table to sym.toml for #{path}"

  def message({:no_lsp_for_path, path, extensions}),
    do: "no configured LSP handles #{path}; configured extensions: #{Enum.join(extensions, " ")}"

  def message({:no_lsp_for_workspace, root, extensions}),
    do:
      "no configured language server has matching files under #{root}; " <>
        "configured extensions: #{Enum.join(extensions, " ")}"

  def message({:symbol_not_found, name, []}), do: ~s(no symbol named "#{name}")

  def message({:symbol_not_found, name, similar}),
    do: ~s(no symbol named "#{name}"; the servers suggest: #{Enum.join(similar, ", ")})

  def message({:no_symbol_at, path, line, column}),
    do: "no symbol at #{path}:#{line}:#{column}"

  def message({:file_read, path, reason}), do: "cannot read #{path}: #{message(reason)}"

  def message({:executable_not_found, command}),
    do: "language server executable not found: #{command}"

  def message({:server_exited, status}), do: "the language server exited with status #{status}"
  def message({:server_start_failed, detail}), do: "cannot start the language server: #{detail}"

  def message({:initialize_failed, detail}),
    do: "the language server failed to initialize: #{detail}"

  def message({:lsp_client_down, reason}),
    do: "the language server connection failed: #{inspect(reason)}"

  def message(:lsp_timeout), do: "timed out waiting for the language server"
  def message({:lsp_error, code, text}), do: "language server error #{code}: #{text}"

  def message({:invalid_server_message, reason}),
    do: "the language server sent an unreadable message: #{inspect(reason)}"

  def message(:timeout), do: "Timed out waiting for a complete request line"
  def message(:closed), do: "Connection closed before a complete request was received"
  def message(:emsgsize), do: "Request exceeds the 65536-byte limit"

  def message(reason) when is_binary(reason), do: reason
  def message(reason) when is_atom(reason), do: reason |> :file.format_error() |> List.to_string()
  def message(reason), do: "Unexpected failure: #{inspect(reason)}"
end
