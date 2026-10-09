defmodule Symd.TransportTest do
  use ExUnit.Case, async: true

  alias Symd.{Profile, Transport}

  setup do
    profile = %Profile{
      add: fn "dexter" -> :ok end,
      list: fn -> {:ok, []} end,
      remove: fn _ -> flunk("unexpected remove") end,
      command: fn _ -> flunk("unexpected command") end
    }

    %{profile: profile}
  end

  test "one-shot mode reads a request and writes exactly one response", %{profile: profile} do
    {:ok, input} = StringIO.open(~s({"op":"add","lsp":"dexter"}\n))
    {:ok, output} = StringIO.open("")

    assert Transport.once(profile, input, output) == 0
    assert {"", response} = StringIO.contents(output)
    assert JSON.decode!(response) == %{"ok" => true, "result" => %{"lsp" => "dexter"}}
    assert length(String.split(response, "\n", trim: true)) == 1
  end

  test "one-shot mode returns an error and exit status 1 for missing, malformed, or oversized input",
       %{profile: profile} do
    # Valid JSON behind 64 KiB of spaces: only the size limit can reject it. If
    # it got through, `list` would succeed and the exit status would be 0.
    oversized = String.duplicate(" ", 65_536) <> ~s({"op":"list"}\n)

    for request <- ["", "{\n", oversized] do
      {:ok, input} = StringIO.open(request)
      {:ok, output} = StringIO.open("")

      assert Transport.once(profile, input, output) == 1
      assert {"", response} = StringIO.contents(output)

      assert %{"ok" => false, "error" => %{"code" => "invalid_request"}} = JSON.decode!(response)
    end
  end

  test "socket mode preserves its listener and serves clients after a malformed request", %{
    profile: profile
  } do
    # Keep Unix socket paths below macOS's length limit, even when TMPDIR is long.
    path = "/tmp/sym-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
    on_exit(fn -> File.rm(path) end)

    assert {:ok, listener} = Transport.listen(path)
    server = Task.async(fn -> Transport.serve(profile, listener) end)
    assert {:error, _} = Transport.listen(path)
    assert File.exists?(path)

    for {request, expected} <- [{"{\n", false}, {~s({"op":"list"}\n), true}] do
      {:ok, socket} =
        :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
          :binary,
          active: false,
          packet: :line
        ])

      :ok = :gen_tcp.send(socket, request)
      assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
      assert JSON.decode!(response)["ok"] == expected
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      :gen_tcp.close(socket)
    end

    :gen_tcp.close(listener)
    assert Task.await(server) == :ok
  end
end
