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
    {:ok, _registry} = Registry.start_link(keys: :unique, name: @registry)
    {:ok, _supervisor} = DynamicSupervisor.start_link(name: @supervisor, strategy: :one_for_one)
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
