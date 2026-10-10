defmodule Symd.Lsp.Client do
  @moduledoc """
  Owns one language-server process and speaks JSON-RPC with it over stdio.

  One client exists per configured LSP and workspace root, started lazily by
  `Symd.Servers` on the first query that needs it. The initialize handshake
  runs during init, so the caller that triggers a cold start waits for it;
  after that, requests are correlated by id and the GenServer never blocks on
  the server inside a callback, which lets in-flight queries overlap.

  Document state follows the disk. `sync/2` reads the file and sends didOpen,
  or a full didChange when the content differs from what the server last saw,
  because agents edit files between queries without telling anyone. The
  server's stderr is inherited by the VM and ends up in the daemon log.

  A client that nobody has queried for a while stops itself and releases its
  server — that is where the memory lives. Clients are temporary children,
  so the next query simply starts a fresh one and pays a cold start.
  """

  use GenServer

  alias Symd.Lsp.{Uri, Wire}

  @handshake_timeout 15_000
  @request_timeout 60_000
  @sync_timeout 15_000
  @settle_ms 300
  @quiet_wait 15_000
  @idle_after 15 * 60_000

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Runs one LSP request and returns its result. Failures come back as values."
  def request(client, method, params, timeout \\ @request_timeout) do
    GenServer.call(client, {:request, method, params}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :lsp_timeout}
    :exit, {reason, _call} -> {:error, {:lsp_client_down, reason}}
  end

  @doc "Aligns the server's view of `path` with disk and returns the file content."
  def sync(client, path, timeout \\ @sync_timeout) do
    GenServer.call(client, {:sync, path}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :lsp_timeout}
    :exit, {reason, _call} -> {:error, {:lsp_client_down, reason}}
  end

  @doc """
  Waits, up to a bound, until the server looks idle: no active `$/progress`
  work and a short settle period since the last document we sent it. Opening
  a file can start a whole project load (tsserver does); answers given during
  it are confidently incomplete, which is worse than being slow.
  """
  def await_quiet(client, max_wait \\ @quiet_wait) do
    poll_quiet(client, System.monotonic_time(:millisecond) + max_wait)
  end

  defp poll_quiet(client, deadline) do
    quiet? =
      try do
        GenServer.call(client, :quiet?)
      catch
        :exit, _reason -> true
      end

    cond do
      quiet? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(100)
        poll_quiet(client, deadline)
    end
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    root = Keyword.fetch!(opts, :root)
    args = Keyword.get(opts, :args, [])

    # Trapping exits makes a supervisor shutdown run terminate/2, so the
    # server always gets its goodbye.
    Process.flag(:trap_exit, true)

    with {:ok, executable} <- resolve(command),
         {:ok, port} <- open_port(executable, args, root),
         {:ok, buffer} <- handshake(port, root) do
      idle_after = Keyword.get(opts, :idle_after, @idle_after)
      Process.send_after(self(), :idle_check, idle_after)

      {:ok,
       %{
         port: port,
         buffer: buffer,
         next_id: 2,
         pending: %{},
         documents: %{},
         progress: MapSet.new(),
         settle_ms: Keyword.get(opts, :settle_ms, @settle_ms),
         last_activity: System.monotonic_time(:millisecond),
         idle_after: idle_after,
         last_used: System.monotonic_time(:millisecond)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    id = state.next_id

    send_message(state.port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })

    {:noreply, %{used(state) | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
  end

  def handle_call({:sync, path}, _from, state) do
    state = used(state)

    case File.read(path) do
      {:ok, content} -> {:reply, {:ok, content}, sync_document(state, path, content)}
      {:error, reason} -> {:reply, {:error, {:file_read, path, reason}}, state}
    end
  end

  def handle_call(:quiet?, _from, state) do
    since_activity = System.monotonic_time(:millisecond) - state.last_activity
    {:reply, MapSet.size(state.progress) == 0 and since_activity >= state.settle_ms, state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    dispatch(%{state | buffer: state.buffer <> chunk})
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:shutdown, {:server_exited, status}}, fail_pending(state, {:server_exited, status})}
  end

  def handle_info(:idle_check, state) do
    idle_for = System.monotonic_time(:millisecond) - state.last_used

    if map_size(state.pending) == 0 and idle_for >= state.idle_after do
      # Nobody asked anything for a while: release the server. The next
      # query starts a fresh one, which costs a cold start, not an answer.
      {:stop, {:shutdown, :idle}, state}
    else
      Process.send_after(self(), :idle_check, max(state.idle_after - idle_for, 100))
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # A polite goodbye: some servers linger on stdin EOF alone. Best-effort —
    # the port may already be gone when the server died first.
    send_message(state.port, %{"jsonrpc" => "2.0", "id" => state.next_id, "method" => "shutdown"})
    send_message(state.port, %{"jsonrpc" => "2.0", "method" => "exit"})
    Port.close(state.port)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp dispatch(state) do
    case Wire.decode(state.buffer) do
      {:ok, message, rest} ->
        dispatch(handle_message(%{state | buffer: rest}, message))

      :more ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:shutdown, {:invalid_server_message, reason}},
         fail_pending(state, {:invalid_server_message, reason})}
    end
  end

  defp handle_message(state, %{"id" => id} = message) when not is_map_key(message, "method") do
    {from, pending} = Map.pop(state.pending, id)
    if from, do: GenServer.reply(from, result(message))
    %{used(state) | pending: pending}
  end

  defp handle_message(state, %{"id" => _, "method" => _} = server_request) do
    answer_server(state.port, server_request)
    state
  end

  defp handle_message(state, %{"method" => "$/progress", "params" => %{"token" => token} = params}) do
    progress =
      case params["value"] do
        %{"kind" => "begin"} -> MapSet.put(state.progress, token)
        %{"kind" => "end"} -> MapSet.delete(state.progress, token)
        _report -> state.progress
      end

    %{touch(state) | progress: progress}
  end

  defp handle_message(state, _notification), do: state

  defp touch(state), do: %{state | last_activity: System.monotonic_time(:millisecond)}
  defp used(state), do: %{state | last_used: System.monotonic_time(:millisecond)}

  defp result(%{"error" => %{"code" => code, "message" => message}}),
    do: {:error, {:lsp_error, code, message}}

  defp result(%{"error" => error}), do: {:error, {:lsp_error, 0, inspect(error)}}
  defp result(message), do: {:ok, Map.get(message, "result")}

  defp fail_pending(state, reason) do
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, reason})
    %{state | pending: %{}}
  end

  # Startup ----------------------------------------------------------------

  defp resolve(command) do
    cond do
      String.contains?(command, "/") ->
        # Service.open made config-relative commands absolute already.
        if File.exists?(command),
          do: {:ok, command},
          else: {:error, {:executable_not_found, command}}

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, {:executable_not_found, command}}
    end
  end

  defp open_port(executable, args, root) do
    {:ok,
     Port.open(
       {:spawn_executable, String.to_charlist(executable)},
       [:binary, :exit_status, args: args, cd: root]
     )}
  rescue
    error -> {:error, {:server_start_failed, Exception.message(error)}}
  end

  defp handshake(port, root) do
    uri = Uri.from_path(root)

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "processId" => String.to_integer(System.pid()),
        "clientInfo" => %{"name" => "symd"},
        "rootUri" => uri,
        "workspaceFolders" => [%{"uri" => uri, "name" => Path.basename(root)}],
        "capabilities" => %{
          "general" => %{"positionEncodings" => ["utf-16"]},
          "textDocument" => %{
            "documentSymbol" => %{"hierarchicalDocumentSymbolSupport" => true},
            "definition" => %{"linkSupport" => true},
            "references" => %{},
            "synchronization" => %{}
          },
          "workspace" => %{"symbol" => %{}}
        }
      }
    })

    await_initialize(port, "", System.monotonic_time(:millisecond) + @handshake_timeout)
  end

  defp await_initialize(port, buffer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:initialize_failed, "timed out waiting for the initialize response"}}
    else
      receive do
        {^port, {:data, chunk}} -> drain_handshake(port, buffer <> chunk, deadline)
        {^port, {:exit_status, status}} -> {:error, {:server_exited, status}}
      after
        remaining ->
          {:error, {:initialize_failed, "timed out waiting for the initialize response"}}
      end
    end
  end

  defp drain_handshake(port, buffer, deadline) do
    case Wire.decode(buffer) do
      {:ok, %{"id" => 1} = message, rest} when not is_map_key(message, "method") ->
        case message do
          %{"error" => error} ->
            {:error, {:initialize_failed, inspect(error)}}

          _result ->
            send_message(port, %{"jsonrpc" => "2.0", "method" => "initialized", "params" => %{}})
            {:ok, rest}
        end

      {:ok, message, rest} ->
        answer_server(port, message)
        drain_handshake(port, rest, deadline)

      :more ->
        await_initialize(port, buffer, deadline)

      {:error, reason} ->
        {:error, {:invalid_server_message, reason}}
    end
  end

  # The server may ask things of its client at any time. We are a deliberately
  # dumb client: every request gets an empty-handed but well-formed answer, so
  # the server never waits on us.
  defp answer_server(port, %{"id" => id, "method" => "workspace/configuration"} = request) do
    items = get_in(request, ["params", "items"]) || []

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => Enum.map(items, fn _item -> nil end)
    })
  end

  defp answer_server(port, %{"id" => id, "method" => _method}) do
    send_message(port, %{"jsonrpc" => "2.0", "id" => id, "result" => nil})
  end

  defp answer_server(_port, _notification), do: :ok

  # Documents ---------------------------------------------------------------

  defp sync_document(state, path, content) do
    uri = Uri.from_path(path)
    digest = :erlang.md5(content)

    case state.documents[uri] do
      nil ->
        notify(state.port, "textDocument/didOpen", %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => language_id(path),
            "version" => 1,
            "text" => content
          }
        })

        put_in(touch(state).documents[uri], {1, digest})

      {_version, ^digest} ->
        state

      {version, _changed} ->
        notify(state.port, "textDocument/didChange", %{
          "textDocument" => %{"uri" => uri, "version" => version + 1},
          "contentChanges" => [%{"text" => content}]
        })

        put_in(touch(state).documents[uri], {version + 1, digest})
    end
  end

  @language_ids %{
    ".ts" => "typescript",
    ".mts" => "typescript",
    ".cts" => "typescript",
    ".tsx" => "typescriptreact",
    ".js" => "javascript",
    ".mjs" => "javascript",
    ".cjs" => "javascript",
    ".jsx" => "javascriptreact",
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".heex" => "phoenix-heex",
    ".rs" => "rust",
    ".go" => "go",
    ".py" => "python",
    ".rb" => "ruby",
    ".c" => "c",
    ".h" => "c",
    ".cc" => "cpp",
    ".cpp" => "cpp",
    ".hpp" => "cpp",
    ".java" => "java",
    ".kt" => "kotlin",
    ".swift" => "swift",
    ".json" => "json",
    ".yaml" => "yaml",
    ".yml" => "yaml",
    ".toml" => "toml",
    ".html" => "html",
    ".css" => "css",
    ".svelte" => "svelte",
    ".vue" => "vue",
    ".lua" => "lua",
    ".zig" => "zig",
    ".hs" => "haskell",
    ".ml" => "ocaml"
  }

  defp language_id(path) do
    extension = path |> Path.extname() |> String.downcase()
    Map.get(@language_ids, extension, String.trim_leading(extension, "."))
  end

  defp send_message(port, message), do: Port.command(port, Wire.encode(message))

  defp notify(port, method, params),
    do: send_message(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
end
