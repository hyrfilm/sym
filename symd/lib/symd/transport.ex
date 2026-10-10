defmodule Symd.Transport do
  @moduledoc """
  Gets requests into the service and replies back to the caller.

  Our CLI protocol is one JSON line each way, one request per connection.
  Each accepted connection is handled in its own supervised task, so a slow
  semantic query — a language server starting cold can take seconds — never
  blocks the next client, and a crash spoils one connection only. This is our
  own protocol, separate from the LSP framing the daemon speaks to servers.
  """

  alias Symd.{Idle, Service}
  @max_line 65_536

  @doc """
  Opens a Unix socket and restricts its permissions before we start serving it.
  A crashed VM may have left its socket behind. We recover only when a connection
  is refused and the path still identifies that same socket; live listeners and
  other kinds of files stay untouched. Recovery retries the bind once.
  """
  def listen(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, socket} <- bind(path, true) do
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

  defp bind(path, recover?) do
    # Passive line mode gives us complete CLI requests. It isn't LSP framing.
    case :gen_tcp.listen(0, [
           :binary,
           active: false,
           packet: :line,
           packet_size: @max_line,
           ifaddr: {:local, String.to_charlist(path)}
         ]) do
      {:error, :eaddrinuse} when recover? -> recover_socket(path)
      result -> result
    end
  end

  defp recover_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        bind(path, false)

      {:ok, stat} when Bitwise.band(stat.mode, 0o170000) == 0o140000 ->
        case :gen_tcp.connect(
               {:local, String.to_charlist(path)},
               0,
               [:binary, active: false],
               250
             ) do
          {:ok, connection} ->
            :gen_tcp.close(connection)
            {:error, :eaddrinuse}

          {:error, :econnrefused} ->
            remove_stale_socket(path, stat)

          {:error, :enoent} ->
            bind(path, false)

          {:error, reason} ->
            {:error, reason}
        end

      _file_or_error ->
        {:error, :eaddrinuse}
    end
  end

  defp remove_stale_socket(path, original) do
    # Check again after the probe: another start may already have replaced the
    # stale path. This is best-effort recovery in a directory the user controls,
    # not an atomic compare-and-unlink operation in a shared writable directory.
    case File.lstat(path) do
      {:ok, current}
      when current.inode == original.inode and current.major_device == original.major_device and
             current.minor_device == original.minor_device and current.mode == original.mode ->
        case File.rm(path) do
          :ok -> bind(path, false)
          {:error, :enoent} -> bind(path, false)
          error -> error
        end

      {:error, :enoent} ->
        bind(path, false)

      _changed_or_error ->
        {:error, :eaddrinuse}
    end
  end

  @doc """
  Accepts connections until the listener closes and hands each one to a task
  under `supervisor`. A stop request closes the listener from its handler,
  which ends this loop; requests still in flight die with the VM. Every
  accepted connection counts as activity for the idle watchdog. `handle` is
  the request handler — injected so tests can serve canned services.
  """
  def serve(listener, supervisor, handle \\ &Service.request/1) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        Idle.touch()
        hand_off(socket, listener, supervisor, handle)
        serve(listener, supervisor, handle)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hand_off(socket, listener, supervisor, handle) do
    # The task may only touch the socket once it owns it, so it waits for the
    # ownership transfer to complete before reading.
    {:ok, task} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          {:handle, owned} -> handle_connection(owned, listener, handle)
        after
          5_000 -> :ok
        end
      end)

    case :gen_tcp.controlling_process(socket, task) do
      :ok -> send(task, {:handle, socket})
      {:error, _reason} -> :gen_tcp.close(socket)
    end
  end

  defp handle_connection(socket, listener, handle) do
    # A client gets five seconds to send its line; answering it may take as
    # long as the language servers need.
    response =
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, line} -> handle.(line)
        {:error, reason} -> Service.error("invalid_request", reason)
      end

    case response do
      {:daemon, :stop, reply} ->
        :gen_tcp.send(socket, [JSON.encode!(reply), "\n"])
        # Closing the listener is the shutdown signal: the accept loop
        # returns and the executable removes its socket file.
        :gen_tcp.close(listener)

      {:daemon, _control, reply} ->
        :gen_tcp.send(socket, [JSON.encode!(reply), "\n"])

      reply ->
        :gen_tcp.send(socket, [JSON.encode!(reply), "\n"])
    end
  after
    # Each request owns this connection, even when handling it raises.
    :gen_tcp.close(socket)
  end
end
