defmodule Aerotow.FlightCase do
  @moduledoc """
  What the flight tests share: an instance put together by hand (a real
  `Aerotow.Catalog`, `Registry`, `DynamicSupervisor` and
  `Task.Supervisor`, each started with `start_supervised!/2`), a clock the
  test moves, stores in the test's `tmp_dir`, telemetry sent to the test
  process, and ways to look at what a store holds.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aerotow.{Card, Catalog, Flight, Instance, Store}
  alias Aerotow.Flight.Copy
  alias Aerotow.Store.Layout

  @t0 1_763_400_000_000

  @doc "Where every test's clock starts, in unix milliseconds."
  @spec t0() :: integer()
  def t0, do: @t0

  @doc "A clock the test moves: `{clock, set}`, where `set.(t)` sets it."
  @spec clock(integer()) :: {(-> integer()), (integer() -> :ok)}
  def clock(t \\ @t0) do
    agent = start_supervised!({Agent, fn -> t end}, id: make_ref())
    {fn -> Agent.get(agent, & &1) end, fn t -> Agent.update(agent, fn _ -> t end) end}
  end

  @doc """
  An instance in `<dir>/<label>`, with its processes started. Options are
  the instance's fields (`clock:`, `sync_interval:`, `idle:`, …).
  """
  @spec instance(Path.t(), String.t(), keyword()) :: Instance.t()
  def instance(dir, label, opts \\ []) do
    name = :"aerotow_flight_test_#{System.unique_integer([:positive])}"
    names = Instance.names(name)
    root = Path.join(dir, label)

    start_supervised!({Registry, keys: :unique, name: names.registry}, id: names.registry)

    start_supervised!({DynamicSupervisor, name: names.flights, strategy: :one_for_one},
      id: names.flights
    )

    start_supervised!({Task.Supervisor, name: names.tasks}, id: names.tasks)

    start_supervised!(
      {Catalog, path: Path.join(root, "catalog.gldb"), name: names.catalog},
      id: names.catalog
    )

    struct!(
      %Instance{
        name: name,
        id: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower),
        dir: root,
        timing: %{ttl: 30_000, margin: 5_000, grace: 5_000},
        sync_interval: 3_600_000,
        idle: :infinity,
        catalog: names.catalog,
        registry: names.registry,
        flights: names.flights,
        tasks: names.tasks
      },
      opts
    )
  end

  @doc "A `dir` store at `path`, recorded in each instance's catalog."
  @spec dir_store(Path.t(), [Instance.t()], String.t()) :: Store.t()
  def dir_store(path, instances, name \\ "store") do
    {:ok, store} = Store.new(name, path)
    Enum.each(instances, &(:ok = Catalog.put_store(&1.catalog, Store.public(store))))
    store
  end

  @doc "A `file` store at `path`, recorded in each instance's catalog."
  @spec file_store(Path.t(), [Instance.t()], String.t()) :: Store.t()
  def file_store(path, instances, name \\ "disk") do
    {:ok, store} = Store.new(name, path, kind: :file)
    Enum.each(instances, &(:ok = Catalog.put_store(&1.catalog, Store.public(store))))
    store
  end

  @doc "Starts a flight and waits for it to be up."
  @spec fly(Instance.t(), Store.t(), String.t(), Flight.intent(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def fly(instance, store, ref, intent, opts \\ []) do
    case Flight.start([instance: instance, store: store, ref: ref, intent: intent] ++ opts) do
      {:ok, pid} ->
        # Watched from the start, so down/2 sees how it ended whenever it ends.
        Process.monitor(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  @doc "Creates a glider, as a flight."
  @spec create(Instance.t(), Store.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def create(instance, store, ref, card_opts \\ []) do
    {:ok, card} = Card.new(ref, card_opts)
    fly(instance, store, ref, {:create, card})
  end

  @doc "Launches a glider, as a flight."
  @spec launch(Instance.t(), Store.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def launch(instance, store, ref), do: fly(instance, store, ref, :launch)

  @doc "Writes the node `(:N {n: n})` through the flight."
  @spec write(pid(), integer(), keyword()) :: {:ok, term()} | {:error, term()}
  def write(pid, n, opts \\ []),
    do: Flight.run(pid, :write, &Glider.run(&1, "CREATE (:N {n: $n})", n: n), opts)

  @doc "The `n` of every `:N` node, through the flight, in order."
  @spec ns(pid()) :: [integer()]
  def ns(pid) do
    {:ok, {:ok, result}} =
      Flight.run(pid, :read, &Glider.query(&1, "MATCH (x:N) RETURN x.n ORDER BY x.n"))

    Enum.map(result.rows, fn [n] -> n end)
  end

  @doc "The `n` of every `:N` node in a database file, opened and closed here."
  @spec ns_in(Path.t()) :: [integer()]
  def ns_in(path) do
    {:ok, db} = Glider.open(path)

    try do
      {:ok, result} = Glider.query(db, "MATCH (x:N) RETURN x.n ORDER BY x.n")
      Enum.map(result.rows, fn [n] -> n end)
    after
      Glider.close(db)
    end
  end

  @doc """
  What flight `n` of `ref` shipped, restored into a fresh file under `dir`:
  the `n` of every `:N` node in it.
  """
  @spec shipped_ns(Store.t(), String.t(), pos_integer(), Path.t()) :: [integer()]
  def shipped_ns(store, ref, n, dir) do
    {url, opts} = Store.replica(store, Layout.flight_data(ref, n))
    out = Path.join([dir, "restored-#{System.unique_integer([:positive])}", "x.gldb"])
    {:ok, _} = Copy.restore(url, opts, out)
    ns_in(out)
  end

  @doc "Every object in a store, key to body."
  @spec snapshot(Store.t()) :: %{String.t() => binary()}
  def snapshot(store) do
    {:ok, %{objects: objects}} = Store.list(store, "")

    Map.new(objects, fn %{key: key} ->
      {:ok, body} = Store.get(store, key)
      {key, body}
    end)
  end

  @doc "The keys that appeared, changed or went between two snapshots."
  @spec changed(map(), map()) :: [String.t()]
  def changed(before, later) do
    keys = Map.keys(before) ++ Map.keys(later)

    keys
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(before, &1) != Map.get(later, &1)))
    |> Enum.sort()
  end

  @doc "The regular files anywhere under `dir`."
  @spec files_under(Path.t()) :: [Path.t()]
  def files_under(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  @doc """
  Sends the telemetry events named to the test process as
  `{:telemetry, event, measurements, metadata}`, until the test ends.
  """
  @spec listen([[atom()]]) :: :ok
  def listen(events) do
    id = make_ref()
    :ok = :telemetry.attach_many(id, events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def forward(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  @doc "Waits for a flight started by `fly/5` to exit, and answers why."
  @spec down(pid(), timeout()) :: term()
  def down(pid, timeout \\ 10_000) do
    assert_receive {:DOWN, _ref, :process, ^pid, reason}, timeout
    reason
  end
end
