defmodule Symd.Service do
  @moduledoc """
  Connects client requests to the workspace's semantic operations.

  Startup turns the config file into a `Symd.Workspace`. After that, every
  connection sends its request here. Requests are validated strictly — a
  misspelled or extra field is an error, not something to guess about — and
  every reply is an envelope the CLI can print without knowing the operation.
  Control results are tagged so the transport can act on them.
  """

  alias Symd.{Config, Semantic, Workspace}

  @protocol 2

  @doc """
  Reads the config and builds the workspace. The workspace root is the
  config file's directory, and config-relative commands become absolute so
  they mean the same thing no matter where the daemon was started from.
  No language server is touched here; they start on first use.
  """
  def open(config_path) do
    with {:ok, toml} <- File.read(config_path),
         {:ok, lsps} <- Config.parse(toml) do
      root = Path.dirname(Path.expand(config_path))

      lsps =
        Enum.map(lsps, fn lsp ->
          if String.contains?(lsp.command, "/"),
            do: %{lsp | command: Path.expand(lsp.command, root)},
            else: lsp
        end)

      {:ok, Workspace.new(root, lsps)}
    end
  end

  @doc """
  Decodes a request and passes it to `handle/2`. Bad JSON becomes an error
  reply so it only spoils that request. Transport owns framing and size
  limits; this function deals with the contents of a request.
  """
  def request(workspace, json) do
    case JSON.decode(json) do
      {:ok, request} -> handle(workspace, request)
      {:error, _reason} -> error("invalid_request", "expected a JSON request")
    end
  end

  @doc """
  Handles semantic and daemon-control messages in our small public protocol.
  Missing and extra fields are rejected so a misspelled option can't silently
  change what a request does. Locations are 1-based `line`/`column` in
  codepoints; the semantic layer owns the LSP coordinate conversion.
  """
  def handle(workspace, %{"op" => "symbols", "path" => path} = request)
      when map_size(request) == 2 and is_binary(path) and byte_size(path) > 0 do
    reply(Semantic.symbols(workspace, path))
  end

  def handle(workspace, %{"op" => op, "name" => name} = request)
      when op in ["def", "refs"] and map_size(request) == 2 and is_binary(name) and
             byte_size(name) > 0 do
    case op do
      "def" -> reply(Semantic.definition(workspace, name))
      "refs" -> reply(Semantic.references(workspace, name))
    end
  end

  def handle(
        workspace,
        %{"op" => op, "path" => path, "line" => line, "column" => column} = request
      )
      when op in ["def", "refs"] and map_size(request) == 4 and is_binary(path) and
             byte_size(path) > 0 and is_integer(line) and line >= 1 and is_integer(column) and
             column >= 1 do
    at = %{path: path, line: line, column: column}

    case op do
      "def" -> reply(Semantic.definition(workspace, at))
      "refs" -> reply(Semantic.references(workspace, at))
    end
  end

  # Management messages use the same socket as semantic requests. The
  # protocol number lets the launcher verify that it found a compatible symd.
  def handle(_workspace, %{"op" => "status"} = request) when map_size(request) == 1 do
    {:daemon, :status,
     %{
       "ok" => true,
       "result" => %{
         "service" => "symd",
         "protocol" => @protocol,
         "state" => "running",
         "pid" => System.pid()
       }
     }}
  end

  def handle(_workspace, %{"op" => "stop"} = request) when map_size(request) == 1 do
    # A stop is an explicit control result. Transport sends the acknowledgement
    # before closing the listener, so the executable can unlink its own socket.
    {:daemon, :stop,
     %{
       "ok" => true,
       "result" => %{"service" => "symd", "protocol" => @protocol, "state" => "stopping"}
     }}
  end

  def handle(_workspace, _request),
    do:
      error(
        "invalid_request",
        "expected symbols with path, def/refs with name or with path+line+column, status, or stop"
      )

  defp reply({:ok, result}), do: %{"ok" => true, "result" => result}
  defp reply({:error, reason}), do: error(code(reason), reason)

  # Stable codes for clients; the message is for the person reading it.
  defp code({:no_lsp_for_path, _path, _extensions}), do: "unsupported_file"
  defp code({:symbol_not_found, _name, _similar}), do: "symbol_not_found"
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
  def message({:no_lsp_for_path, path, []}),
    do: "no LSPs are configured; add an [lsp.<name>] table to sym.toml for #{path}"

  def message({:no_lsp_for_path, path, extensions}),
    do: "no configured LSP handles #{path}; configured extensions: #{Enum.join(extensions, " ")}"

  def message({:symbol_not_found, name, []}), do: ~s(no symbol named "#{name}")

  def message({:symbol_not_found, name, similar}),
    do: ~s(no symbol named "#{name}"; the servers suggest: #{Enum.join(similar, ", ")})

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
