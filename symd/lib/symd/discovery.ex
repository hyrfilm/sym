defmodule Symd.Discovery do
  @moduledoc """
  Finds the workspace a query belongs to, starting from the caller's working
  directory.

  Walking upward, the first directory containing `sym.toml` or `.git` is the
  workspace root; `sym.toml` wins when both sit in the same directory. The
  search never continues past a repository boundary, so a stray `sym.toml`
  above a checkout cannot capture it. A root marked only by `.git` reads the
  global config — one file can serve every repository on the machine.

  The source root inside a project (`src/`, a `tsconfig.json` directory) is
  deliberately not resolved here: language servers do their own project
  discovery from the workspace root we hand them.
  """

  @doc """
  Returns `{:ok, %{root: root, config: config_path}}` for the workspace
  around `cwd`, `{:error, {:no_workspace, cwd}}` when no directory up the
  chain is marked, or `{:error, {:no_config, root, global}}` when a git root
  has no `sym.toml` and no global config exists either.
  """
  def workspace(cwd) do
    cwd = Path.expand(cwd)
    find(cwd, cwd)
  end

  defp find(dir, cwd) do
    config = Path.join(dir, "sym.toml")

    cond do
      File.regular?(config) ->
        {:ok, %{root: dir, config: config}}

      # A worktree keeps a .git file rather than a directory; both mark a root.
      File.exists?(Path.join(dir, ".git")) ->
        global = global_config()

        if File.regular?(global),
          do: {:ok, %{root: dir, config: global}},
          else: {:error, {:no_config, dir, global}}

      true ->
        parent = Path.dirname(dir)
        if parent == dir, do: {:error, {:no_workspace, cwd}}, else: find(parent, cwd)
    end
  end

  @doc "The config used for roots that have no sym.toml of their own."
  def global_config do
    base = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([base, "sym", "sym.toml"])
  end
end
