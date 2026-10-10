defmodule Symd.IdleTest do
  # Uses the globally named watchdog that Transport touches, so not async.
  use ExUnit.Case, async: false

  alias Symd.{Idle, Transport}

  defp socket_path do
    path = "/tmp/sym-idle-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
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

  test "an idle daemon closes its listener, but never under a request in flight" do
    path = socket_path()
    {:ok, supervisor} = Task.Supervisor.start_link([])
    {:ok, listener} = Transport.listen(path)
    parent = self()

    handler = fn line ->
      if String.contains?(line, "block") do
        send(parent, {:blocked, self()})

        receive do
          :release -> %{"ok" => true, "result" => %{"blocked" => true}}
        end
      else
        %{"ok" => true, "result" => %{}}
      end
    end

    start_supervised!({Idle, listener: listener, supervisor: supervisor, limit: 300, tick: 50})
    server = Task.async(fn -> Transport.serve(listener, supervisor, handler) end)

    # An in-flight request keeps the daemon alive well past its idle limit.
    slow = connect(path)
    :ok = :gen_tcp.send(slow, ~s({"op":"block"}\n))
    assert_receive {:blocked, blocked}, 2_000
    Process.sleep(600)
    assert Task.yield(server, 0) == nil

    send(blocked, :release)
    assert {:ok, reply} = :gen_tcp.recv(slow, 0, 5_000)
    assert JSON.decode!(reply)["result"]["blocked"] == true
    :gen_tcp.close(slow)

    # With nothing left in flight, the watchdog closes the listener and serve
    # returns — the same shutdown path as a stop request.
    assert Task.await(server, 5_000) == :ok
  end

  test "activity pushes the idle deadline out" do
    path = socket_path()
    {:ok, supervisor} = Task.Supervisor.start_link([])
    {:ok, listener} = Transport.listen(path)
    handler = fn _line -> %{"ok" => true, "result" => %{}} end

    start_supervised!({Idle, listener: listener, supervisor: supervisor, limit: 400, tick: 50})
    server = Task.async(fn -> Transport.serve(listener, supervisor, handler) end)

    # Keep connecting past the original deadline; the daemon stays up.
    for _request <- 1..3 do
      Process.sleep(250)
      assert {:ok, _reply} = roundtrip(path, ~s({"op":"anything"}\n))
    end

    assert Task.yield(server, 0) == nil
    assert Task.await(server, 5_000) == :ok
  end
end
