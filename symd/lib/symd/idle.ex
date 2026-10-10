defmodule Symd.Idle do
  @moduledoc """
  Shuts an idle daemon down by closing its listener.

  Auto-start is what makes this safe: the daemon exists to keep language
  servers warm, and once nothing has connected for a while there is nothing
  left worth keeping warm — the next query simply starts a fresh daemon.
  Shutdown waits until no connection task is running, so a query in flight
  is never cut off, and closing the listener reuses the `stop` path: the
  accept loop ends and the executable removes its own socket.
  """

  use GenServer

  @limit 30 * 60_000
  @tick 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records client activity. The transport calls this on every connection."
  def touch(name \\ __MODULE__) do
    # Cast so an absent watchdog (tests serve without one) is a no-op.
    GenServer.cast(name, :touch)
  end

  @impl true
  def init(opts) do
    state = %{
      listener: Keyword.fetch!(opts, :listener),
      supervisor: Keyword.fetch!(opts, :supervisor),
      limit: Keyword.get(opts, :limit, @limit),
      tick: Keyword.get(opts, :tick, @tick),
      last: System.monotonic_time(:millisecond)
    }

    Process.send_after(self(), :tick, state.tick)
    {:ok, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, %{state | last: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:tick, state) do
    idle? = System.monotonic_time(:millisecond) - state.last >= state.limit
    busy? = Task.Supervisor.children(state.supervisor) != []

    if idle? and not busy? do
      :gen_tcp.close(state.listener)
      {:stop, :normal, state}
    else
      Process.send_after(self(), :tick, state.tick)
      {:noreply, state}
    end
  end
end
