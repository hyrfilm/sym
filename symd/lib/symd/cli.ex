defmodule Symd.CLI do
  @moduledoc """
  The small entry point for the `symd` executable.

  It gets the profile ready, then hands control to the selected transport.
  Both modes take the same startup path, so a one-shot invocation doesn't
  need a daemon to have created its profile first.
  """

  alias Symd.{Service, Transport}

  @doc """
  Parses the flags and starts the requested mode. This is the executable's
  boundary, so errors can print to stderr and exit the VM here; the modules
  underneath return ordinary results for their callers to handle.
  """
  def main(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [config: :string, socket: :string, oneshot: :boolean, help: :boolean]
      )

    cond do
      opts[:help] ->
        IO.puts("Usage: symd [--config sym.toml] [--socket .sym/symd.sock | --oneshot]")

      rest != [] or invalid != [] or (opts[:oneshot] && opts[:socket]) ->
        fail("invalid arguments; use --help")

      true ->
        # Read and prepare the config before opening a socket. A config error
        # should leave us with an explanation, not a leftover socket file.
        config = Keyword.get(opts, :config, "sym.toml")

        case Service.open(config) do
          {:ok, profile} -> run(profile, opts)
          {:error, reason} -> fail("cannot open profile: #{inspect(reason)}")
        end
    end
  end

  defp run(profile, opts) do
    if opts[:oneshot] do
      System.halt(Transport.once(profile))
    else
      path = Keyword.get(opts, :socket, ".sym/symd.sock")

      case Transport.listen(path) do
        {:ok, listener} ->
          IO.puts(:stderr, "symd listening on #{path}")

          try do
            Transport.serve(profile, listener)
          after
            # This handles normal returns and exceptions. A VM shutdown can
            # still leave a stale socket, which the run instructions explain.
            :gen_tcp.close(listener)
            File.rm(path)
          end

        {:error, reason} ->
          fail("cannot listen on #{path}: #{inspect(reason)}")
      end
    end
  end

  defp fail(message) do
    # One-shot stdout belongs to the reply protocol, including on failures.
    IO.puts(:stderr, "symd: #{message}")
    System.halt(1)
  end
end
