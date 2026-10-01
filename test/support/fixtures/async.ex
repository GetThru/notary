defmodule Outlaw.Fixtures.AsyncJob do
  @moduledoc false
  # A job that completes asynchronously: `request/1` replies immediately and
  # moves to :pending, then a few milliseconds later (via `handle_info`, not
  # the caller) moves on to :done on its own — an internal/reactive action the
  # mapping cannot invoke directly (Outlaw spec §4.3).
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def request(pid), do: GenServer.call(pid, :request)
  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(opts) do
    {:ok,
     %{
       status: :idle,
       complete_to: Keyword.get(opts, :complete_to, :done),
       never_complete: Keyword.get(opts, :never_complete, false)
     }}
  end

  @impl true
  def handle_call(:request, _from, %{status: status} = state) when status in [:idle, :done] do
    unless state.never_complete do
      Process.send_after(self(), :complete, Enum.random(0..3))
    end

    {:reply, :ok, %{state | status: :pending}}
  end

  def handle_call(:request, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:complete, state), do: {:noreply, %{state | status: state.complete_to}}
end
