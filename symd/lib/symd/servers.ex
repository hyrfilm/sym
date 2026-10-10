defmodule Symd.Servers do
  @moduledoc """
  Lazily starts and finds the language-server client for a configured LSP.

  Clients register under `{lsp name, workspace root}`. They are temporary
  children: when a server dies, its client goes away with it, and the next
  query starts a fresh one, instead of a supervisor hammering a broken
  command in a restart loop.
  """

  alias Symd.Lsp.Client

  @registry Symd.Registry
  @supervisor Symd.ServerSupervisor

  @doc "Starts the registry and supervisor the clients live under."
  def start_runtime do
    :ok = ensure(Registry.start_link(keys: :unique, name: @registry))
    :ok = ensure(DynamicSupervisor.start_link(name: @supervisor, strategy: :one_for_one))
    :ok
  end

  defp ensure({:ok, _pid}), do: :ok
  defp ensure({:error, {:already_started, _pid}}), do: :ok

  @doc """
  Stops every running client under `root`. `Symd.Workspaces` calls this when
  a root's configuration changes, so no server keeps answering through a
  command or arguments the config no longer names.
  """
  def stop_root(root) do
    for pid <-
          Registry.select(@registry, [{{{:_, :"$1"}, :"$2", :_}, [{:==, :"$1", root}], [:"$2"]}]) do
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    :ok
  end

  @doc "Returns the running client for this LSP, starting it on first use."
  def client(root, lsp) do
    key = {lsp.name, root}

    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> start(key, root, lsp)
    end
  end

  defp start(key, root, lsp) do
    spec = %{
      id: Client,
      restart: :temporary,
      start:
        {Client, :start_link,
         [
           [
             command: lsp.command,
             args: lsp.args,
             root: root,
             name: {:via, Registry, {@registry, key}}
           ]
         ]}
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
