defmodule Symd.Workspace do
  @moduledoc """
  What a running daemon knows: the workspace root, the configured LSPs, and
  how to reach their servers.

  `request` and `sync` are injected functions so the semantic layer can be
  exercised against canned LSP replies. The real functions go through
  `Symd.Servers`, which starts language servers on first use.
  """

  alias Symd.Lsp.Client
  alias Symd.Servers

  @enforce_keys [:root, :lsps, :request, :sync]
  defstruct [:root, :lsps, :request, :sync, :settle]

  @doc "A workspace whose queries reach real language servers."
  def new(root, lsps) do
    %__MODULE__{
      root: root,
      lsps: lsps,
      request: fn lsp, method, params ->
        with {:ok, client} <- Servers.client(root, lsp),
             do: Client.request(client, method, params)
      end,
      sync: fn lsp, path ->
        with {:ok, client} <- Servers.client(root, lsp),
             do: Client.sync(client, path)
      end,
      settle: fn lsp ->
        with {:ok, client} <- Servers.client(root, lsp),
             do: Client.await_quiet(client)
      end
    }
  end
end
