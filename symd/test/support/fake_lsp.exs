# A scripted stdio language server for client tests: real pipes, real framing.
# It answers initialize, records document notifications, and implements:
#
#   test/echo      -> result: the request's params
#   test/delay     -> result after params["ms"] milliseconds, out of order
#   test/documents -> result: the documents it has seen, sorted by uri
#   test/progress  -> emits a $/progress notification first, then replies
#   test/exit      -> halts with status 3 without replying
#
# Responses go through one writer process so delayed replies can't interleave
# bytes with in-order ones.
defmodule FakeLsp do
  def main do
    writer = spawn_link(&write_loop/0)
    Process.register(writer, :writer)
    loop(%{})
  end

  defp loop(documents) do
    case read_message() do
      :eof -> :ok
      message -> loop(handle(message, documents))
    end
  end

  defp handle(%{"method" => "initialize", "id" => id}, documents) do
    respond(id, %{"capabilities" => %{}})
    documents
  end

  defp handle(%{"method" => "textDocument/didOpen", "params" => params}, documents) do
    document = params["textDocument"]

    Map.put(documents, document["uri"], %{
      "uri" => document["uri"],
      "version" => document["version"],
      "text" => document["text"]
    })
  end

  defp handle(%{"method" => "textDocument/didChange", "params" => params}, documents) do
    %{"uri" => uri, "version" => version} = params["textDocument"]
    [%{"text" => text}] = params["contentChanges"]
    Map.update!(documents, uri, &%{&1 | "version" => version, "text" => text})
  end

  defp handle(%{"method" => "test/documents", "id" => id}, documents) do
    respond(id, documents |> Map.values() |> Enum.sort_by(& &1["uri"]))
    documents
  end

  defp handle(%{"method" => "test/echo", "id" => id, "params" => params}, documents) do
    respond(id, params)
    documents
  end

  defp handle(
         %{"method" => "test/delay", "id" => id, "params" => %{"ms" => ms} = params},
         documents
       ) do
    spawn(fn ->
      Process.sleep(ms)
      respond(id, params)
    end)

    documents
  end

  defp handle(
         %{
           "method" => "test/progress",
           "id" => id,
           "params" => %{"token" => token, "kind" => kind}
         },
         documents
       ) do
    notify("$/progress", %{"token" => token, "value" => %{"kind" => kind}})
    respond(id, nil)
    documents
  end

  defp handle(%{"method" => "test/exit"}, _documents) do
    System.halt(3)
  end

  defp handle(_notification, documents), do: documents

  defp respond(id, result) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp notify(method, params) do
    write(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp write(message) do
    body = JSON.encode!(message)
    send(:writer, {:write, "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"})
  end

  defp write_loop do
    receive do
      {:write, data} ->
        IO.binwrite(:stdio, data)
        write_loop()
    end
  end

  defp read_message do
    with {:ok, headers} <- read_headers(""),
         [_line, length] <- Regex.run(~r/content-length:\s*(\d+)/i, headers),
         body when is_binary(body) <- IO.binread(:stdio, String.to_integer(length)) do
      JSON.decode!(body)
    else
      _eof_or_damage -> :eof
    end
  end

  defp read_headers(acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case IO.binread(:stdio, 1) do
        byte when is_binary(byte) -> read_headers(acc <> byte)
        _eof_or_error -> :eof
      end
    end
  end
end

FakeLsp.main()
