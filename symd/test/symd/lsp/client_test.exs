defmodule Symd.Lsp.ClientTest do
  use ExUnit.Case, async: true

  alias Symd.Lsp.{Client, Uri}

  @fake Path.expand("../../support/fake_lsp.exs", __DIR__)

  defp start_client(root, opts \\ []) do
    elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

    {:ok, client} =
      Client.start_link([command: elixir, args: [@fake], root: root] ++ opts)

    client
  end

  @tag :tmp_dir
  test "handshakes and correlates concurrent requests answered out of order", %{tmp_dir: dir} do
    client = start_client(dir)

    slow =
      Task.async(fn -> Client.request(client, "test/delay", %{"ms" => 500, "tag" => "slow"}) end)

    # Give the slow request a head start on the wire.
    Process.sleep(100)
    assert {:ok, %{"tag" => "fast"}} = Client.request(client, "test/echo", %{"tag" => "fast"})
    assert Task.yield(slow, 0) == nil
    assert {:ok, %{"tag" => "slow", "ms" => 500}} = Task.await(slow)
  end

  @tag :tmp_dir
  test "document sync follows the disk", %{tmp_dir: dir} do
    path = Path.join(dir, "watched.ts")
    uri = Uri.from_path(path)
    File.write!(path, "one")
    client = start_client(dir)

    assert {:ok, "one"} = Client.sync(client, path)
    # Unchanged content is not re-announced.
    assert {:ok, "one"} = Client.sync(client, path)

    assert {:ok, [%{"uri" => ^uri, "version" => 1, "text" => "one"}]} =
             Client.request(client, "test/documents", %{})

    File.write!(path, "two")
    assert {:ok, "two"} = Client.sync(client, path)

    assert {:ok, [%{"uri" => ^uri, "version" => 2, "text" => "two"}]} =
             Client.request(client, "test/documents", %{})

    # Later queries may only sync a seed; previously opened files still refresh.
    File.write!(path, "three")
    assert :ok = Client.await_quiet(client)

    assert {:ok, [%{"uri" => ^uri, "version" => 3, "text" => "three"}]} =
             Client.request(client, "test/documents", %{})

    assert {:error, {:file_read, _missing, :enoent}} =
             Client.sync(client, Path.join(dir, "missing.ts"))

    File.rm!(path)
    assert :ok = Client.await_quiet(client)
    assert {:ok, []} = Client.request(client, "test/documents", %{})

    File.write!(path, "recreated")
    assert {:ok, "recreated"} = Client.sync(client, path)

    assert {:ok, [%{"uri" => ^uri, "version" => 1, "text" => "recreated"}]} =
             Client.request(client, "test/documents", %{})
  end

  @tag :tmp_dir
  test "await_quiet waits for the server's work-done progress to end", %{tmp_dir: dir} do
    client = start_client(dir, settle_ms: 50)

    assert {:ok, nil} =
             Client.request(client, "test/progress", %{"token" => "load", "kind" => "begin"})

    waiter = Task.async(fn -> Client.await_quiet(client, 5_000) end)
    Process.sleep(200)
    assert Task.yield(waiter, 0) == nil

    assert {:ok, nil} =
             Client.request(client, "test/progress", %{"token" => "load", "kind" => "end"})

    assert Task.await(waiter) == :ok
  end

  @tag :tmp_dir
  test "an unused client stops itself and releases its server", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    client = start_client(dir, idle_after: 150)

    assert {:ok, %{"tag" => "hi"}} = Client.request(client, "test/echo", %{"tag" => "hi"})
    assert_receive {:EXIT, ^client, {:shutdown, :idle}}, 2_000
  end

  @tag :tmp_dir
  test "idle shutdown never interrupts a request in flight", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    client = start_client(dir, idle_after: 100)

    # The request takes several idle periods to answer; it must still arrive.
    assert {:ok, %{"ms" => 600}} = Client.request(client, "test/delay", %{"ms" => 600})
    assert_receive {:EXIT, ^client, {:shutdown, :idle}}, 2_000
  end

  @tag :tmp_dir
  test "a dying server fails the requests that were waiting on it", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    client = start_client(dir)

    assert {:error, {:server_exited, 3}} = Client.request(client, "test/exit", %{})
    assert_receive {:EXIT, ^client, {:shutdown, {:server_exited, 3}}}, 2_000
  end

  @tag :tmp_dir
  test "a missing executable is an error value, not a crash", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)

    assert {:error, {:executable_not_found, "no-such-lsp-anywhere"}} =
             Client.start_link(command: "no-such-lsp-anywhere", args: [], root: dir)
  end
end
