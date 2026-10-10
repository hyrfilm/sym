defmodule Symd.WorkspacesTest do
  # Starts the globally named client runtime so stop_root has a registry.
  use ExUnit.Case, async: false

  alias Symd.{Servers, Workspace, Workspaces}

  setup do
    :ok = Servers.start_runtime()
    {:ok, pid} = Workspaces.start_link(name: nil)
    %{workspaces: pid}
  end

  @toml """
  [lsp.ts]
  command = "typescript-language-server"
  args = ["--stdio"]
  extensions = [".ts"]
  """

  @tag :tmp_dir
  test "resolves, caches, and lists workspaces per root", %{tmp_dir: dir, workspaces: pid} do
    config = Path.join(dir, "sym.toml")
    File.write!(config, @toml)
    nested = Path.join(dir, "src")
    File.mkdir_p!(nested)

    assert {:ok, %Workspace{root: ^dir} = workspace} = Workspaces.fetch(pid, nested)
    assert [%{name: "ts", command: "typescript-language-server"}] = workspace.lsps

    # Unchanged content: the cached workspace is reused, from any cwd inside.
    assert {:ok, cached} = Workspaces.fetch(pid, dir)
    assert cached.request == workspace.request

    assert Workspaces.list(pid) == [%{"root" => dir, "config" => config}]
  end

  @tag :tmp_dir
  test "a config edit rebuilds the workspace and stops the root's clients", %{
    tmp_dir: dir,
    workspaces: pid
  } do
    config = Path.join(dir, "sym.toml")
    File.write!(config, @toml)
    assert {:ok, _workspace} = Workspaces.fetch(pid, dir)

    # A fake client registered under this root stands in for a live server.
    {:ok, client} =
      DynamicSupervisor.start_child(Symd.ServerSupervisor, %{
        id: :fake,
        restart: :temporary,
        start:
          {Agent, :start_link,
           [fn -> :ok end, [name: {:via, Registry, {Symd.Registry, {"ts", dir}}}]]}
      })

    File.write!(config, String.replace(@toml, "typescript-language-server", "./tools/tls"))
    assert {:ok, rebuilt} = Workspaces.fetch(pid, dir)

    # The relative command resolves against the config file's directory, and
    # the old client is gone: the next query starts from the new command.
    assert [%{command: command}] = rebuilt.lsps
    assert command == Path.join(dir, "tools/tls")
    refute Process.alive?(client)
  end

  @tag :tmp_dir
  test "config problems are errors naming the offending file", %{tmp_dir: dir, workspaces: pid} do
    config = Path.join(dir, "sym.toml")
    File.write!(config, "not toml [")

    assert {:error, {:invalid_config, ^config, _message}} = Workspaces.fetch(pid, dir)

    File.write!(config, "# no lsp tables\n")

    assert {:error, {:invalid_config, ^config, message}} = Workspaces.fetch(pid, dir)
    assert message =~ "[lsp.<name>]"
  end
end
