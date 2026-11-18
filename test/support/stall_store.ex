defmodule Aerotow.StallStore do
  @moduledoc """
  A `dir` store that a test can tell to fail or to stall: an
  `Aerotow.Store.Objects` that hands every operation to
  `Aerotow.Store.Dir`, after asking its controller (this module, as a
  process) whether it may.

      ctl = start_supervised!({Aerotow.StallStore, watcher: self()})
      store = Aerotow.StallStore.wrap(store, ctl)

      Aerotow.StallStore.set(ctl, [:put, :replica], :block)
      # a put or a replica asked for now waits, and the watcher is sent
      # {:stalled, op, key}
      Aerotow.StallStore.release(ctl)

  An operation is `:get`, `:put`, `:delete`, `:list` or `:replica` (the
  replica url a shipping pass asks for before it ships). Each is `:ok`,
  `:fail` (it answers an error at once) or `:block` (it waits until
  `release/1` or `set/3` lets it go).
  """

  @behaviour Aerotow.Store.Objects

  use GenServer

  alias Aerotow.Store
  alias Aerotow.Store.Dir

  @ops [:get, :put, :delete, :list, :replica]

  @doc "Starts a controller. `watcher:` is told of every operation that stalls."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The same store, its operations going through the controller `ctl`."
  @spec wrap(Store.t(), pid()) :: Store.t()
  def wrap(%Store{kind: :dir, config: config} = store, ctl),
    do: %{store | mod: __MODULE__, config: %{inner: config, ctl: ctl}}

  @doc "Sets what the operations named do: `:ok`, `:fail` or `:block`."
  @spec set(pid(), atom() | [atom()], :ok | :fail | :block) :: :ok
  def set(ctl, ops, mode) when mode in [:ok, :fail, :block],
    do: GenServer.call(ctl, {:set, List.wrap(ops), mode})

  @doc "Lets everything through again, and lets go of what is waiting."
  @spec release(pid()) :: :ok
  def release(ctl), do: set(ctl, @ops, :ok)

  # ------------------------------------------------------------------ the store

  @impl Aerotow.Store.Objects
  def init(name, url, opts), do: Dir.init(name, url, opts)

  @impl Aerotow.Store.Objects
  def get(config, key), do: gated(config, :get, key, fn -> Dir.get(config.inner, key) end)

  @impl Aerotow.Store.Objects
  def put(config, key, body, opts),
    do: gated(config, :put, key, fn -> Dir.put(config.inner, key, body, opts) end)

  @impl Aerotow.Store.Objects
  def delete(config, key),
    do: gated(config, :delete, key, fn -> Dir.delete(config.inner, key) end)

  @impl Aerotow.Store.Objects
  def list(config, prefix, opts),
    do: gated(config, :list, prefix, fn -> Dir.list(config.inner, prefix, opts) end)

  @impl Aerotow.Store.Objects
  def replica(config, prefix),
    do: gated(config, :replica, prefix, fn -> Dir.replica(config.inner, prefix) end)

  @impl Aerotow.Store.Objects
  def probe(config), do: Dir.probe(config.inner)

  defp gated(%{ctl: ctl}, op, key, fun) do
    case GenServer.call(ctl, {:gate, op, key}, :infinity) do
      :ok -> fun.()
      :fail -> {:error, "the store is failing (#{op} #{key})"}
    end
  end

  # ------------------------------------------------------------------ the controller

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       modes: Map.new(@ops, &{&1, :ok}),
       waiting: [],
       watcher: Keyword.get(opts, :watcher)
     }}
  end

  @impl GenServer
  def handle_call({:gate, op, key}, from, state) do
    case Map.fetch!(state.modes, op) do
      :block ->
        if state.watcher, do: send(state.watcher, {:stalled, op, key})
        {:noreply, %{state | waiting: [{op, from} | state.waiting]}}

      mode ->
        {:reply, mode, state}
    end
  end

  def handle_call({:set, ops, mode}, _from, state) do
    modes = Enum.reduce(ops, state.modes, &Map.put(&2, &1, mode))

    {go, still} =
      Enum.split_with(state.waiting, fn {op, _from} -> Map.fetch!(modes, op) != :block end)

    Enum.each(go, fn {op, from} -> GenServer.reply(from, Map.fetch!(modes, op)) end)
    {:reply, :ok, %{state | modes: modes, waiting: still}}
  end
end
