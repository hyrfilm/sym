defmodule Symd.Transport do
  @moduledoc """
  Gets requests into the service and replies back to the caller.

  Our CLI protocol is one JSON line each way. Socket mode handles one request
  per connection; one-shot mode does the same over stdin/stdout. Both dispatch
  through `Symd.Service`, so choosing a transport doesn't change the operation.
  This is our own protocol, separate from the LSP framing we'll eventually use.
  """

  alias Symd.Service
  @max_line 65_536

  @doc """
  Opens a Unix socket and restricts its permissions before we start serving it.
  An existing path is an error: it might belong to a live daemon, so startup
  mustn't unlink it to make room for another one.
  """
  def listen(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         # :gen_tcp also supports Unix sockets. Passive line mode lets us
         # receive complete request lines without writing our own buffer.
         {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             active: false,
             packet: :line,
             packet_size: @max_line,
             ifaddr: {:local, String.to_charlist(path)}
           ]) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, socket}

        {:error, reason} ->
          :gen_tcp.close(socket)
          File.rm(path)
          {:error, reason}
      end
    end
  end

  @doc """
  Serves clients one at a time until the listener closes.
  A client gets five seconds to send its line; package installation itself
  may take longer. This keeps writes through this daemon sequential without
  adding a job system or a process for every request.
  """
  def serve(profile, listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          response =
            case :gen_tcp.recv(socket, 0, 5_000) do
              {:ok, line} -> Service.request(profile, line)
              {:error, reason} -> Service.error("invalid_request", reason)
            end

          :gen_tcp.send(socket, [JSON.encode!(response), "\n"])
        after
          # Each request owns this connection, even when handling it raises.
          :gen_tcp.close(socket)
        end

        serve(profile, listener)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads one request, writes one reply, and returns exit status 0 or 1.
  The caller owns exiting the VM. Tests can pass StringIO devices here and
  inspect the same wire messages without starting a subprocess.
  """
  def once(profile, input \\ :stdio, output \\ :stdio) do
    response =
      case IO.binread(input, :line) do
        # Socket line mode checks this limit for us; stdio needs its own check
        # before we hand the line to the service.
        line when is_binary(line) and byte_size(line) > @max_line ->
          Service.error("invalid_request", "request exceeds #{@max_line} bytes")

        line when is_binary(line) ->
          Service.request(profile, line)

        _eof_or_error ->
          Service.error("invalid_request", "expected one JSON request line")
      end

    IO.binwrite(output, [JSON.encode!(response), "\n"])
    if response["ok"], do: 0, else: 1
  end
end
