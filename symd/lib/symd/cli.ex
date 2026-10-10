defmodule Symd.CLI do
  @moduledoc """
  The small entry point for the `symd` executable.

  It builds the workspace from the config file, starts the runtime processes
  that own language-server clients, and serves the socket until a stop
  request closes the listener.
  """

  alias Symd.{Servers, Service, Transport}

  @doc """
  Parses the flags and starts serving. This is the executable's boundary, so
  errors can print to stderr and exit the VM here; the modules underneath
  return ordinary results for their callers to handle.
  """
  def main(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [config: :string, socket: :string, help: :boolean])

    cond do
      opts[:help] ->
        IO.puts("Usage: symd [--config sym.toml] [--socket .sym/symd.sock]")

      rest != [] or invalid != [] ->
        fail("invalid arguments; use --help")

      true ->
        # Read and check the config before opening a socket. A config error
        # should leave us with an explanation, not a leftover socket file.
        config = Keyword.get(opts, :config, "sym.toml")

        case Service.open(config) do
          {:ok, workspace} ->
            run(workspace, opts)

          {:error, reason} ->
            fail("cannot open workspace from #{config}: #{Service.message(reason)}")
        end
    end
  end

  defp run(workspace, opts) do
    path = Keyword.get(opts, :socket, ".sym/symd.sock")
    :ok = Servers.start_runtime()
    {:ok, connections} = Task.Supervisor.start_link([])

    case Transport.listen(path) do
      {:ok, listener} ->
        IO.puts(:stderr, "symd listening on #{path}")

        try do
          Transport.serve(workspace, listener, connections)
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
