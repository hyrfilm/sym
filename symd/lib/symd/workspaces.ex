defmodule Symd.Workspaces do
  @moduledoc """
  Resolves and caches one `Symd.Workspace` per workspace root.

  Every request re-reads its config file — they are small — and the cached
  workspace is reused while the content is unchanged. When the config
  changes, the root's language-server clients are stopped before the fresh
  workspace is built, so a re-pointed server can't keep answering with its
  old command or arguments.
  """

  use GenServer

  alias Symd.{Config, Discovery, Servers, Workspace}

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, :ok)
      {:ok, name} -> GenServer.start_link(__MODULE__, :ok, name: name)
      :error -> GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end
  end

  @doc "Returns the workspace that answers queries coming from `cwd`."
  def fetch(server \\ __MODULE__, cwd) do
    GenServer.call(server, {:fetch, cwd})
  end

  @doc "The known workspaces, for status replies: root and config per entry."
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:fetch, cwd}, _from, cache) do
    case resolve(cache, cwd) do
      {:ok, entry} ->
        {:reply, {:ok, entry.workspace}, Map.put(cache, entry.workspace.root, entry)}

      {:error, reason} ->
        {:reply, {:error, reason}, cache}
    end
  end

  def handle_call(:list, _from, cache) do
    list =
      cache
      |> Map.values()
      |> Enum.map(&%{"root" => &1.workspace.root, "config" => &1.config})
      |> Enum.sort_by(& &1["root"])

    {:reply, list, cache}
  end

  defp resolve(cache, cwd) do
    with {:ok, %{root: root, config: config}} <- Discovery.workspace(cwd),
         {:ok, toml} <- read(config) do
      digest = :erlang.md5(toml)

      case cache[root] do
        %{config: ^config, digest: ^digest} = entry ->
          {:ok, entry}

        stale ->
          with {:ok, lsps} <- parse(config, toml) do
            if stale, do: Servers.stop_root(root)
            {:ok, %{config: config, digest: digest, workspace: build(root, config, lsps)}}
          end
      end
    end
  end

  defp read(config) do
    case File.read(config) do
      {:ok, toml} -> {:ok, toml}
      {:error, posix} -> {:error, {:config_unreadable, config, posix}}
    end
  end

  defp parse(config, toml) do
    case Config.parse(toml) do
      {:ok, lsps} -> {:ok, lsps}
      {:error, message} -> {:error, {:invalid_config, config, message}}
    end
  end

  defp build(root, config, lsps) do
    # Relative commands mean "next to the file that names them": the project
    # root for a project config, ~/.config/sym for the global one.
    lsps =
      Enum.map(lsps, fn lsp ->
        if String.contains?(lsp.command, "/"),
          do: %{lsp | command: Path.expand(lsp.command, Path.dirname(config))},
          else: lsp
      end)

    Workspace.new(root, lsps)
  end
end
