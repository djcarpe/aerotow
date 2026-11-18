defmodule Aerotow.Flight.Slots do
  @moduledoc """
  How many shipping passes run at once in this VM.

  A pass's sync runs on a dirty I/O scheduler and, while it copies a base,
  waits for the writer to be polled; the poll needs a dirty I/O scheduler
  too. With as many passes as there are such schedulers, every one of them
  waits for a poll that cannot run, and nothing ships again. So at most
  that many less two passes run at once, VM-wide; a pass beyond them waits
  for a slot.

  A slot belongs to the process that took it and is given back when that
  process gives it back or dies, so a pass that is killed (abandoned after
  `sync_timeout`, or by a lost flight) never keeps one.

  One process, registered as `#{inspect(__MODULE__)}`, keeps the count. An
  application can start it in its own tree (`child_spec/1`); otherwise the
  first pass starts it, unlinked.
  """

  use GenServer

  @doc "Starts the keeper of slots, registered under this module's name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Runs `fun` holding a slot, waiting for one first."
  @spec run((-> result)) :: result when result: term()
  def run(fun) do
    keeper = keeper()
    :ok = GenServer.call(keeper, :take, :infinity)

    try do
      fun.()
    after
      GenServer.cast(keeper, {:give, self()})
    end
  end

  @doc "How many slots there are: the VM's dirty I/O schedulers less two, at least one."
  @spec limit() :: pos_integer()
  def limit, do: max(1, :erlang.system_info(:dirty_io_schedulers) - 2)

  defp keeper do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{holders: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call(:take, {pid, _} = from, state) do
    if map_size(state.holders) < limit(),
      do: {:reply, :ok, hold(state, pid)},
      else: {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
  end

  @impl true
  def handle_cast({:give, pid}, state), do: {:noreply, state |> free(pid) |> next()}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, state |> free(pid) |> next()}

  defp hold(state, pid),
    do: %{state | holders: Map.put(state.holders, pid, Process.monitor(pid))}

  defp free(state, pid) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        state

      {monitor, holders} ->
        Process.demonitor(monitor, [:flush])
        %{state | holders: holders}
    end
  end

  # The next waiter that is still alive gets the slot.
  defp next(state) do
    if map_size(state.holders) < limit() do
      case :queue.out(state.waiting) do
        {{:value, {pid, _} = from}, waiting} ->
          state = %{state | waiting: waiting}

          if Process.alive?(pid) do
            GenServer.reply(from, :ok)
            next(hold(state, pid))
          else
            next(state)
          end

        {:empty, _} ->
          state
      end
    else
      state
    end
  end
end
