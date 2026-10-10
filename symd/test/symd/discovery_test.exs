defmodule Symd.DiscoveryTest do
  # Manipulates XDG_CONFIG_HOME, which is process-global.
  use ExUnit.Case, async: false

  alias Symd.Discovery

  defp with_global(dir, fun) do
    previous = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", dir)

    try do
      fun.()
    after
      if previous,
        do: System.put_env("XDG_CONFIG_HOME", previous),
        else: System.delete_env("XDG_CONFIG_HOME")
    end
  end

  @tag :tmp_dir
  test "the nearest sym.toml marks the workspace root", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "sym.toml"), "")
    nested = Path.join(dir, "packages/web/src")
    File.mkdir_p!(nested)

    assert Discovery.workspace(nested) ==
             {:ok, %{root: dir, config: Path.join(dir, "sym.toml")}}
  end

  @tag :tmp_dir
  test "a nested sym.toml wins over the one above it", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "sym.toml"), "")
    package = Path.join(dir, "packages/web")
    File.mkdir_p!(Path.join(package, "src"))
    File.write!(Path.join(package, "sym.toml"), "")

    assert {:ok, %{root: ^package}} = Discovery.workspace(Path.join(package, "src"))
  end

  @tag :tmp_dir
  test "a git root uses the global config and ends the search", %{tmp_dir: dir} do
    # The sym.toml above the repository must not capture it.
    File.write!(Path.join(dir, "sym.toml"), "")
    repo = Path.join(dir, "checkout")
    nested = Path.join(repo, "lib/deep")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.mkdir_p!(nested)

    xdg = Path.join(dir, "xdg")
    global = Path.join(xdg, "sym/sym.toml")

    with_global(xdg, fn ->
      assert Discovery.workspace(nested) == {:error, {:no_config, repo, global}}

      File.mkdir_p!(Path.dirname(global))
      File.write!(global, "")
      assert Discovery.workspace(nested) == {:ok, %{root: repo, config: global}}
    end)
  end

  @tag :tmp_dir
  test "a project sym.toml wins over the global config at a git root", %{tmp_dir: dir} do
    repo = Path.join(dir, "checkout")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.write!(Path.join(repo, "sym.toml"), "")

    xdg = Path.join(dir, "xdg")
    File.mkdir_p!(Path.join(xdg, "sym"))
    File.write!(Path.join(xdg, "sym/sym.toml"), "")

    with_global(xdg, fn ->
      assert Discovery.workspace(repo) ==
               {:ok, %{root: repo, config: Path.join(repo, "sym.toml")}}
    end)
  end

  @tag :tmp_dir
  test "a worktree's .git file also marks a root", %{tmp_dir: dir} do
    repo = Path.join(dir, "worktree")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".git"), "gitdir: /elsewhere")

    xdg = Path.join(dir, "xdg")
    File.mkdir_p!(Path.join(xdg, "sym"))
    File.write!(Path.join(xdg, "sym/sym.toml"), "")

    with_global(xdg, fn ->
      assert {:ok, %{root: ^repo}} = Discovery.workspace(repo)
    end)
  end

  test "no marker anywhere is a workspace error" do
    # Outside the repository: ExUnit tmp dirs live under it, and the walk
    # would find this project's own sym.toml.
    base = "/tmp/sym-nowhere-#{System.pid()}-#{System.unique_integer([:positive])}"
    dir = Path.join(base, "deep")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(base) end)

    assert Discovery.workspace(dir) == {:error, {:no_workspace, dir}}
  end
end
