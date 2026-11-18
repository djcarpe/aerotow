defmodule Aerotow.ModesTest do
  # Where an aloft glider's pages live: switching between memory and disk
  # from flight to flight, "auto", who decides, memory's bounds, a memory
  # flight lost with log that never shipped, and a hot set that travels.
  # Not async: stores and the S3 fake make atoms, which Aerotow.CardTest
  # counts, and directories are made unwritable.
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import Aerotow.FlightCase, only: [t0: 0, files_under: 1]

  alias Aerotow.{Card, Catalog, FlightCase, Flight, Instance, Lease, StallStore, Store}
  alias Aerotow.Flight.Copy
  alias Aerotow.Store.Layout

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"
  @hot 1_048_576
  @long %{ttl: 300_000, margin: 5_000, grace: 5_000}
  @short %{ttl: 3_000, margin: 1_000, grace: 1_000}

  defp ns(tow, ref \\ @ref) do
    case Aerotow.query(tow, ref, "MATCH (x:N) RETURN x.n ORDER BY x.n") do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [n] -> n end)
      error -> error
    end
  end

  defp count(tow, ref \\ @ref) do
    {:ok, %{rows: [[n]]}} = Aerotow.query(tow, ref, "MATCH (x:N) RETURN count(x)")
    n
  end

  defp write(tow, n, opts \\ []), do: Aerotow.run(tow, @ref, "CREATE (:N {n: $n})", %{n: n}, opts)

  # `count` nodes of about a hundred bytes each, a thousand to a batch.
  defp fill(tow, ref, count) do
    s = String.duplicate("x", 80)

    1..count
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      batch = for i <- chunk, do: {"CREATE (:N {n: $n, s: $s})", %{n: 1_000_000 + i, s: s}}
      {:ok, _} = Aerotow.write_batch(tow, ref, batch)
    end)
  end

  defp info(tow, ref \\ @ref) do
    {:ok, infos} = Aerotow.aloft(tow)
    Enum.find(infos, &(&1.ref == ref))
  end

  defp dir_tow(dir, label, opts \\ []) do
    store = Path.join(dir, "store")
    tow(Path.join(dir, label), [stores: [{"store", store}], default_store: "store"] ++ opts)
  end

  # ------------------------------------------------------------------ switching

  test "switching: flown memory, disk, memory, disk, it keeps every write, and a mode changed aloft takes effect at the next launch",
       %{tmp_dir: dir} do
    a = dir_tow(dir, "a")
    {:ok, _} = Aerotow.create(a, @ref, mode: "memory")

    for {{flies, next}, n} <-
          Enum.with_index(
            [{"memory", "disk"}, {"disk", "memory"}, {"memory", "disk"}, {"disk", "memory"}],
            1
          ) do
      assert %{mode: ^flies} = info(a)
      assert ns(a) == Enum.to_list(1..n//1) -- [n]
      {:ok, 1} = write(a, n)

      # The card changes now; the flight does not.
      assert {:ok, %Card{mode: ^next}} = Aerotow.update(a, @ref, mode: next)
      assert %{mode: ^flies} = info(a)
      assert ns(a) == Enum.to_list(1..n)

      :ok = Aerotow.land(a, @ref)
      :ok = Aerotow.launch(a, @ref)
    end

    assert %{mode: "memory"} = info(a)
    assert ns(a) == [1, 2, 3, 4]
  end

  # ------------------------------------------------------------------ auto

  test "auto: a new glider starts in memory, one whose card says it is past memory_threshold launches from disk, one under it in memory, and info, aloft and the launch telemetry say which",
       %{tmp_dir: dir} do
    listen([[:aerotow, :launch, :stop]])
    a = dir_tow(dir, "a", memory_threshold: 100_000)

    {:ok, %Card{mode: "auto"}} = Aerotow.create(a, @ref)
    assert %{mode: "memory"} = info(a)

    assert_receive {:telemetry, [:aerotow, :launch, :stop], _,
                    %{ref: @ref, mode: "memory", flight: 1}}

    :ok = fill(a, @ref, 2_000)
    :ok = Aerotow.land(a, @ref)
    assert {:ok, %Card{bytes: bytes}} = Aerotow.card(a, @ref)
    assert bytes >= 100_000

    :ok = Aerotow.launch(a, @ref)
    assert %{mode: "disk"} = info(a)
    assert {:ok, [%{ref: @ref, mode: "disk"}]} = Aerotow.aloft(a)

    assert_receive {:telemetry, [:aerotow, :launch, :stop], _,
                    %{ref: @ref, mode: "disk", flight: 2}}

    assert count(a) == 2_000
    :ok = Aerotow.land(a, @ref)

    {:ok, _} = Aerotow.create(a, "small/g")
    {:ok, 1} = Aerotow.run(a, "small/g", "CREATE (:N {n: 1})")
    :ok = Aerotow.land(a, "small/g")
    assert {:ok, %Card{bytes: small}} = Aerotow.card(a, "small/g")
    assert small < 100_000
    :ok = Aerotow.launch(a, "small/g")
    assert %{mode: "memory"} = info(a, "small/g")
    assert ns(a, "small/g") == [1]
  end

  # ------------------------------------------------------------------ precedence

  test "precedence: a store's mode and hot override the card's, and the instance's override both",
       %{tmp_dir: dir} do
    plain = Path.join(dir, "plain")
    disky = Path.join(dir, "disky")
    stores = [{"plain", plain}, {"disky", disky, mode: "disk", hot: @hot}]
    page = 16_384

    # The card decides where nothing else does.
    a = tow(Path.join(dir, "a"), stores: stores)
    {:ok, _} = Aerotow.create(a, "a/card", store: "plain", mode: "memory")
    assert %{mode: "memory", hot: nil} = info(a, "a/card")
    {:ok, _} = Aerotow.create(a, "a/card-hot", store: "plain", mode: "disk", hot: 2 * @hot)
    assert %{mode: "disk", hot: %{hot_capacity: capacity}} = info(a, "a/card-hot")
    assert capacity == div(2 * @hot, page)

    # The store over the card: mode and hot.
    {:ok, _} = Aerotow.create(a, "a/store", store: "disky", mode: "memory", hot: 2 * @hot)
    assert %{mode: "disk", hot: %{hot_capacity: capacity}} = info(a, "a/store")
    assert capacity == div(@hot, page)

    # The instance over the store and the card.
    b = tow(Path.join(dir, "b"), stores: stores, mode: "memory")
    {:ok, _} = Aerotow.create(b, "b/instance", store: "disky", mode: "disk")
    assert %{mode: "memory", hot: nil} = info(b, "b/instance")

    c = tow(Path.join(dir, "c"), stores: stores, hot: 3 * @hot)
    {:ok, _} = Aerotow.create(c, "c/instance", store: "disky", mode: "memory", hot: 2 * @hot)
    assert %{mode: "disk", hot: %{hot_capacity: capacity}} = info(c, "c/instance")
    assert capacity == div(3 * @hot, page)

    # 0 is "no hot set", and stops the search where it is given.
    d = tow(Path.join(dir, "d"), stores: stores, hot: 0)
    {:ok, _} = Aerotow.create(d, "d/none", store: "disky")
    assert %{mode: "disk", hot: nil} = info(d, "d/none")
  end

  # ------------------------------------------------------------------ bounds

  test "memory is bounded: the budget counts a memory flight's bytes, and lands the least recently used for room",
       %{tmp_dir: dir} do
    listen([[:aerotow, :evict]])
    a = dir_tow(dir, "a", budget: 300_000, mode: "memory")

    {:ok, _} = Aerotow.create(a, "g/one")
    :ok = fill(a, "g/one", 2_000)
    assert %{mode: "memory", bytes: one} = info(a, "g/one")
    assert one > 200_000

    {:ok, _} = Aerotow.create(a, "g/two")
    :ok = fill(a, "g/two", 2_000)
    assert %{bytes: two} = info(a, "g/two")
    assert one + two >= 300_000

    # Nothing on disk holds either of them: only their bytes in memory
    # make the instance land one.
    assert files_under(Path.join([dir, "a", "flights"])) == []
    {:ok, _} = Aerotow.create(a, "g/three")

    assert_receive {:telemetry, [:aerotow, :evict], %{bytes: ^one},
                    %{ref: "g/one", why: :budget}},
                   10_000

    assert info(a, "g/one") == nil
    assert count(a, "g/two") == 2_000
  end

  test "memory is bounded: a glider that does not fit is {:error, {:launch, reason}} with glider's reason and leaves nothing; under auto it launches from disk",
       %{tmp_dir: dir} do
    a = dir_tow(dir, "a")
    {:ok, _} = Aerotow.create(a, @ref, mode: "disk")
    :ok = fill(a, @ref, 20_000)
    :ok = Aerotow.land(a, @ref)
    :ok = stop_supervised!(a)
    store = Path.join(dir, "store")
    {:ok, plain} = Store.new("store", store)
    before = FlightCase.snapshot(plain)

    small = dir_tow(dir, "small", mode: "memory", max_memory: 65_536)
    {:ok, _} = Aerotow.scan(small, "store")
    assert {:error, {:launch, reason}} = Aerotow.launch(small, @ref)
    assert reason =~ "max_memory is"
    assert {:ok, []} = Aerotow.aloft(small)
    assert files_under(Path.join([dir, "small", "flights"])) == []
    assert files_under(Path.join([dir, "small", "orphans"])) == []

    # Its flight record was taken and landed with nothing shipped; nothing
    # else in the store changed.
    assert {:ok, %Lease{n: 2, landed: true, shipped: nil}} = Lease.current(plain, @ref)

    assert FlightCase.changed(before, FlightCase.snapshot(plain)) == [
             Layout.flight_record(@ref, 2)
           ]

    :ok = stop_supervised!(small)

    auto =
      dir_tow(dir, "auto", mode: "auto", max_memory: 65_536, memory_threshold: 1_073_741_824)

    {:ok, _} = Aerotow.scan(auto, "store")
    :ok = Aerotow.launch(auto, @ref)
    assert %{mode: "disk"} = info(auto)
    assert count(auto) == 20_000
  end

  # ------------------------------------------------------------------ lost, in memory

  describe "the store is unreachable, in memory" do
    setup %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      on_exit(fn -> writable(store, true) end)
      %{store: store}
    end

    test "R14: a memory flight lost with unshipped log writes a replica to orphans/, orphans/1 lists it, and when the store is back it is carried into the next flight",
         %{tmp_dir: dir, store: store} do
      {clock, set} = clock(t0())

      a =
        tow(Path.join(dir, "a"),
          stores: [{"store", store}],
          default_store: "store",
          clock: clock,
          timing: @short
        )

      listen([[:aerotow, :lease, :lost], [:aerotow, :flight, :orphaned]])
      {:ok, _} = Aerotow.create(a, @ref, mode: "memory")
      {:ok, 1} = write(a, 1, sync: :commit)

      writable(store, false)
      {:ok, 1} = write(a, 2)
      {:ok, 1} = write(a, 3)

      set.(t0() + @short.ttl - @short.margin)
      assert_receive {:telemetry, [:aerotow, :lease, :lost], _, %{ref: @ref, flight: 1}}, 10_000

      assert_receive {:telemetry, [:aerotow, :flight, :orphaned], _, %{ref: @ref, path: kept}},
                     10_000

      assert kept == Path.join([dir, "a", "orphans", "store", @ref <> ".1.replica"])
      assert File.dir?(kept)
      assert files_under(Path.join([dir, "a", "flights"])) == []

      assert {:ok,
              [%{ref: @ref, store: "store", flight: 1, path: ^kept, bytes: bytes, carry: true}]} =
               Aerotow.orphans(a)

      assert bytes > 0

      # The store is back, and nobody took off meanwhile: the next launch
      # restores the replica and carries on the flight's lineage.
      writable(store, true)
      assert ns(a) == [1, 2, 3]
      assert %{mode: "memory", flight: 2} = info(a)
      assert {:ok, []} = Aerotow.orphans(a)
      {:ok, plain} = Store.new("plain", store)
      assert {:ok, %Lease{n: 2, from: %{carried: true}}} = Lease.current(plain, @ref)

      :ok = Aerotow.land(a, @ref)
      b = tow(Path.join(dir, "b"), stores: [{"store", store}], clock: clock, timing: @short)
      assert ns(b) == [1, 2, 3]
    end
  end

  test "R15: a memory flight's replica in orphans/ is carried into a flight from disk as well",
       %{tmp_dir: dir} do
    {clock, set} = FlightCase.clock()
    a = FlightCase.instance(dir, "a", clock: clock, mode: "memory")
    store = FlightCase.dir_store(Path.join(dir, "store"), [a])
    stall_ctl = start_supervised!({StallStore, watcher: self()})
    stall = StallStore.wrap(store, stall_ctl)

    {:ok, pid} = FlightCase.create(a, stall, @ref)
    {:ok, _} = FlightCase.write(pid, 1)
    {:ok, _} = FlightCase.write(pid, 2)
    StallStore.set(stall_ctl, [:put, :replica], :fail)
    {:ok, lease} = Lease.read(store, @ref, 1)
    set.(lease.expires_at - @long.margin)
    assert %{state: :lost} = Flight.info(pid)
    assert {:shutdown, :lost} = FlightCase.down(pid)
    StallStore.release(stall_ctl)

    orphan = Copy.orphan_replica_path(a, store, @ref, 1)
    assert {:ok, %{flight: 1}} = Copy.read_marker(orphan)

    # The same instance, flying from disk now.
    {:ok, pid} = FlightCase.fly(%Instance{a | mode: "disk"}, store, @ref, {:carry, orphan})
    assert %{flight: 2, mode: "disk"} = Flight.info(pid)
    assert Copy.exists?(Copy.path(a, store, @ref))
    refute Copy.exists?(orphan)
    assert FlightCase.ns(pid) == [1, 2]
    {:ok, _} = Flight.sync(pid)
    assert FlightCase.shipped_ns(store, @ref, 2, dir) == [1, 2]
    assert {:ok, %Lease{from: %{carried: true}}} = Lease.read(store, @ref, 2)
    :ok = Flight.land(pid)
    assert {:ok, %Card{nodes: 2}} = Catalog.card(a.catalog, @ref)
  end

  # ------------------------------------------------------------------ hot

  test "hot: a glider landed with a warm hot set and launched on another instance is warm at its first lookups",
       %{tmp_dir: dir} do
    {_fake, s3} = s3()
    stores = [{"s3", "s3://graphs/gliders", s3}]
    # A small page cache: glider counts heat in ticks of as many lookups as
    # the cache has frames, so a small one warms in a few hundred reads.
    cache = 16 * 1_048_576
    a = tow(Path.join(dir, "a"), stores: stores, default_store: "s3", cache_size: cache)

    {:ok, _} = Aerotow.create(a, @ref, mode: "disk", hot: @hot)
    :ok = fill(a, @ref, 3_000)
    :ok = Aerotow.land(a, @ref)

    # Used again and again, its pages grow hot.
    :ok = Aerotow.launch(a, @ref)
    for _ <- 1..400, do: assert(count_n(a) == 3_000)
    assert %{mode: "disk", hot: %{promotions: promotions, hot_pages: pages}} = info(a)
    assert promotions > 0 and pages > 0
    :ok = Aerotow.land(a, @ref)

    b = tow(Path.join(dir, "b"), stores: stores, cache_size: cache)
    {:ok, _} = Aerotow.scan(b, "s3")
    :ok = Aerotow.launch(b, @ref)
    assert %{mode: "disk", hot: %{prewarmed: prewarmed}} = info(b)
    assert prewarmed > 0

    assert count_n(b) == 3_000
    assert {:ok, %{"hot_hits" => hits, "prewarmed" => ^prewarmed}} = Aerotow.stats(b, @ref)
    assert hits > 0
  end

  # A statement that reads every :N node's properties.
  defp count_n(tow) do
    {:ok, %{rows: [[n]]}} = Aerotow.query(tow, @ref, "MATCH (x:N) WHERE x.n > 0 RETURN count(x)")
    n
  end

  defp writable(root, writable?) do
    mode = if writable?, do: 0o755, else: 0o555

    dirs =
      root
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.dir?/1)

    Enum.each([root | dirs], &File.chmod(&1, mode))
  end
end
