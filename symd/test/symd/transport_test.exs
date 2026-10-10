defmodule Symd.TransportTest do
  use ExUnit.Case, async: true

  alias Symd.{Transport, Workspace}

  @slow_lsp %{name: "slow", command: "x", args: [], extensions: [".slow"]}

  defp workspace(overrides) do
    struct!(
      %Workspace{
        root: "/nowhere",
        lsps: [@slow_lsp],
        request: fn _lsp, method, _params -> flunk("unexpected request #{method}") end,
        sync: fn _lsp, _path -> {:ok, ""} end
      },
      overrides
    )
  end

  # Keep Unix socket paths below macOS's length limit, even when TMPDIR is long.
  defp socket_path(prefix) do
    path = "/tmp/#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line
      ])

    socket
  end

  defp roundtrip(path, request) do
    socket = connect(path)
    :ok = :gen_tcp.send(socket, request)
    reply = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    reply
  end

  test "socket mode preserves its listener and serves clients after a malformed request" do
    path = socket_path("sym")
    {:ok, supervisor} = Task.Supervisor.start_link([])

    assert {:ok, listener} = Transport.listen(path)
    server = Task.async(fn -> Transport.serve(workspace([]), listener, supervisor) end)
    assert {:error, _taken} = Transport.listen(path)
    assert File.exists?(path)

    for {request, expected} <- [{"{\n", false}, {~s({"op":"status"}\n), true}] do
      assert {:ok, response} = roundtrip(path, request)
      assert JSON.decode!(response)["ok"] == expected
    end

    :gen_tcp.close(listener)
    assert Task.await(server) == :ok
  end

  test "a slow request does not block a later client" do
    path = socket_path("sym-slow")
    {:ok, supervisor} = Task.Supervisor.start_link([])
    parent = self()

    workspace =
      workspace(
        request: fn @slow_lsp, "textDocument/documentSymbol", _params ->
          send(parent, {:blocked, self()})

          receive do
            :release -> {:ok, []}
          end
        end
      )

    {:ok, listener} = Transport.listen(path)
    server = Task.async(fn -> Transport.serve(workspace, listener, supervisor) end)

    slow = connect(path)
    :ok = :gen_tcp.send(slow, ~s({"op":"symbols","path":"/repo/a.slow"}\n))
    assert_receive {:blocked, handler}, 2_000

    # The daemon answers a second client while the first is still waiting.
    assert {:ok, response} = roundtrip(path, ~s({"op":"status"}\n))
    assert JSON.decode!(response)["result"]["state"] == "running"

    send(handler, :release)
    assert {:ok, response} = :gen_tcp.recv(slow, 0, 5_000)
    assert JSON.decode!(response) == %{"ok" => true, "result" => %{"symbols" => []}}
    :gen_tcp.close(slow)

    :gen_tcp.close(listener)
    assert Task.await(server) == :ok
  end

  @tag capture_log: true
  test "a crashing handler spoils one connection, not the daemon" do
    path = socket_path("sym-crash")
    {:ok, supervisor} = Task.Supervisor.start_link([])

    workspace =
      workspace(request: fn _lsp, _method, _params -> raise "handler boom" end)

    {:ok, listener} = Transport.listen(path)
    server = Task.async(fn -> Transport.serve(workspace, listener, supervisor) end)

    crashed = connect(path)
    :ok = :gen_tcp.send(crashed, ~s({"op":"symbols","path":"/repo/a.slow"}\n))
    assert {:error, :closed} = :gen_tcp.recv(crashed, 0, 5_000)
    :gen_tcp.close(crashed)

    assert {:ok, response} = roundtrip(path, ~s({"op":"status"}\n))
    assert JSON.decode!(response)["ok"] == true

    :gen_tcp.close(listener)
    assert Task.await(server) == :ok
  end

  test "a stop request acknowledges, closes the listener, and ends serve" do
    path = socket_path("sym-stop")
    {:ok, supervisor} = Task.Supervisor.start_link([])

    {:ok, listener} = Transport.listen(path)
    server = Task.async(fn -> Transport.serve(workspace([]), listener, supervisor) end)

    assert {:ok, response} = roundtrip(path, ~s({"op":"stop"}\n))
    assert JSON.decode!(response)["result"]["state"] == "stopping"
    assert Task.await(server, 5_000) == :ok
  end

  test "startup recovers a socket left behind by a stopped process" do
    path = socket_path("sym-stale")
    assert {:ok, old_listener} = Transport.listen(path)
    :gen_tcp.close(old_listener)
    assert File.exists?(path)

    assert {:ok, listener} = Transport.listen(path)
    :gen_tcp.close(listener)
  end

  test "startup never removes a regular file or a symlink in place of a socket" do
    path = "/tmp/sym-file-#{System.pid()}-#{System.unique_integer([:positive])}"
    target = path <> ".target"

    on_exit(fn ->
      File.rm(path)
      File.rm(target)
    end)

    File.write!(path, "keep me")
    assert {:error, _refused} = Transport.listen(path)
    assert File.read!(path) == "keep me"

    File.rename!(path, target)
    File.ln_s!(target, path)
    assert {:error, _refused} = Transport.listen(path)
    assert File.read_link!(path) == target
    assert File.read!(target) == "keep me"
  end
end
