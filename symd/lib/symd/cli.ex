defmodule Symd.CLI do
  @moduledoc """
  The small entry point for the `symd` executable.

  It starts the runtime processes that own language-server clients and the
  per-root workspace cache, then serves the socket until a stop request or
  the idle watchdog closes the listener. Configuration is not read here:
  every request carries the caller's working directory, and the workspace —
  root and config — is resolved from it on demand.
  """

  alias Symd.{Idle, Servers, Service, Transport, Workspaces}

  @doc """
  Parses the flags and starts serving. This is the executable's boundary, so
  errors can print to stderr and exit the VM here; the modules underneath
  return ordinary results for their callers to handle.
  """
  def main(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [socket: :string, help: :boolean])

    cond do
      opts[:help] ->
        IO.puts("Usage: symd [--socket ~/.sym/symd.sock]")

      rest != [] or invalid != [] ->
        fail("invalid arguments; use --help")

      true ->
        run(Keyword.get(opts, :socket, default_socket()))
    end
  end

  defp default_socket, do: Path.join(System.user_home!(), ".sym/symd.sock")

  defp run(path) do
    :ok = Servers.start_runtime()
    {:ok, _workspaces} = Workspaces.start_link([])
    {:ok, connections} = Task.Supervisor.start_link([])

    case Transport.listen(path) do
      {:ok, listener} ->
        IO.puts(:stderr, "symd listening on #{path}")
        {:ok, _idle} = Idle.start_link(listener: listener, supervisor: connections)

        try do
          Transport.serve(listener, connections)
        after
          # This handles normal returns and exceptions. A VM shutdown can
          # still leave a stale socket, which listen recovers next start.
          :gen_tcp.close(listener)
          File.rm(path)
        end

      {:error, reason} ->
        fail("cannot listen on #{path}: #{Service.message(reason)}")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "symd: #{message}")
    System.halt(1)
  end
end
