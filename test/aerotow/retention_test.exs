defmodule Aerotow.RetentionTest do
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import Aerotow.FlightCase, only: [t0: 0, shipped_ns: 4, snapshot: 1]

  alias Aerotow.{Instance, Lease, Retention, Store}
  alias Aerotow.Store.Layout

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"
  @retention 10_000

  defp write(tow, ref, n), do: Aerotow.run(tow, ref, "CREATE (:N {n: $n})", %{n: n})

  defp flights(store, ref) do
    {:ok, flights} = Lease.flights(store, ref)
    flights
  end

  defp data?(store, ref, n) do
    {:ok, %{objects: objects}} = Store.list(store, Layout.flight_data(ref, n) <> "/")
    objects != []
  end

  defp retain(tow) do
    {:ok, results} = Retention.run(Instance.fetch!(tow))
    results
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "store")
    {clock, set} = clock(t0())
    stores = [{"store", path}]

    a =
      tow(Path.join(dir, "a"),
        stores: stores,
        default_store: "store",
        clock: clock,
        retention: @retention
      )

    {:ok, store} = Store.new("plain", path)
    %{a: a, set: set, store: store, stores: stores, clock: clock}
  end

  test "once a newer flight has a whole base, the holder deletes older flights' records and data older than retention, and no more",
       %{tmp_dir: dir, a: a, set: set, store: store} do
    listen([[:aerotow, :retention, :retired], [:aerotow, :retention, :trimmed]])

    # Flight 1 lands at t0 with a base; flight 2 reads only.
    {:ok, _} = Aerotow.create(a, @ref)
    {:ok, 1} = write(a, @ref, 1)
    :ok = Aerotow.land(a, @ref)
    set.(t0() + 1_000)
    :ok = Aerotow.launch(a, @ref)

    # Flight 1 is the newest with a whole base: kept, however old.
    set.(t0() + 10 * @retention)
    assert [%{ref: @ref, flight: 2, retired: 0}] = retain(a)
    assert flights(store, @ref) == [1, 2]

    # Flight 2 gets a base of its own.
    {:ok, 1} = write(a, @ref, 2)
    {:ok, %{bases: 1}} = Aerotow.sync(a, @ref)

    # Not yet retention past flight 1's landing: kept.
    set.(t0() + @retention)
    assert [%{flight: 2, retired: 0}] = retain(a)
    assert flights(store, @ref) == [1, 2]

    set.(t0() + @retention + 1)
    assert [%{ref: @ref, store: "store", flight: 2, retired: 1, trimmed: trimmed}] = retain(a)
    assert is_integer(trimmed)

    assert_received {:telemetry, [:aerotow, :retention, :retired], %{flights: 1},
                     %{ref: @ref, store: "store", flight: 2}}

    assert_received {:telemetry, [:aerotow, :retention, :trimmed], %{objects: ^trimmed},
                     %{ref: @ref, store: "store", flight: 2}}

    assert flights(store, @ref) == [2]
    refute data?(store, @ref, 1)
    assert shipped_ns(store, @ref, 2, dir) == [1, 2]

    # What is left launches, from flight 2.
    :ok = Aerotow.land(a, @ref)

    assert {:ok, %{rows: [[1], [2]]}} =
             Aerotow.query(a, @ref, "MATCH (x:N) RETURN x.n ORDER BY x.n")
  end

  test "only the holder of a glider's current flight retires its flights, never another glider's",
       %{tmp_dir: dir, a: a, set: set, store: store, stores: stores, clock: clock} do
    # Two gliders, each with an old flight below a newer one with a base.
    for ref <- [@ref, "other/g"] do
      {:ok, _} = Aerotow.create(a, ref)
      :ok = Aerotow.land(a, ref)
      {:ok, 1} = write(a, ref, 1)
      {:ok, %{bases: 1}} = Aerotow.sync(a, ref)
      :ok = Aerotow.land(a, ref)
    end

    set.(t0() + 10 * @retention)
    before = snapshot(store)

    # Hangared everywhere: nobody holds them, nothing goes.
    assert retain(a) == []
    b = tow(Path.join(dir, "b"), stores: stores, clock: clock, retention: @retention)
    assert retain(b) == []
    assert snapshot(store) == before

    # Aloft on B: B holds @ref's flight, and retires @ref's old flights only.
    {:ok, _} = Aerotow.scan(b, "store")
    :ok = Aerotow.launch(b, @ref)
    assert [%{ref: @ref, flight: 3, retired: 1}] = retain(b)
    assert retain(a) == []
    assert flights(store, @ref) == [2, 3]
    assert flights(store, "other/g") == [1, 2]
  end

  test "a flight that is lost runs no retention", %{tmp_dir: dir, store: store} do
    {clock, set} = clock(t0())
    timing = %{ttl: 3_000, margin: 1_000, grace: 1_000}

    c =
      tow(Path.join(dir, "c"),
        stores: [{"store", Path.join(dir, "store")}],
        default_store: "store",
        clock: clock,
        timing: timing,
        retention: @retention
      )

    {:ok, _} = Aerotow.create(c, @ref)
    :ok = Aerotow.land(c, @ref)
    {:ok, 1} = write(c, @ref, 1)
    {:ok, %{bases: 1}} = Aerotow.sync(c, @ref)

    # Far past retention, and past the flight's deadline: it is lost the
    # moment it looks at the clock, and lends nothing.
    set.(t0() + 10 * @retention)
    assert retain(c) == []
    assert flights(store, @ref) == [1, 2]
  end

  test "the server runs a pass every min(retention, 1 hour), at least a minute apart" do
    at = fn ms -> Retention.interval(%Instance{name: :x, id: "", dir: "", retention: ms}) end
    assert at.(86_400_000) == 3_600_000
    assert at.(600_000) == 600_000
    assert at.(1_000) == 60_000
  end
end
