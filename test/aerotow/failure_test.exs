defmodule Aerotow.FailureTest do
  # The rows of the design's "What can go wrong" table, each a test named
  # after its row, with real processes and VMs dying. Not async: VMs start
  # here, and directories are made unwritable.
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import Aerotow.FlightCase, only: [t0: 0, snapshot: 1, changed: 2]

  alias Aerotow.{FakeS3, Instance, Lease, PeerTow, Store}
  alias Aerotow.Store.Layout

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"

  # A lease long enough that nothing renews or runs out unless the test moves a clock.
  @long %{ttl: 300_000, margin: 5_000, grace: 5_000}

  # A short one, for the rows about leases: a flight looks at its clock
  # every ttl / 10 ms of real time.
  @short %{ttl: 3_000, margin: 1_000, grace: 1_000}

  defp ns(tow) do
    case Aerotow.query(tow, @ref, "MATCH (x:N) RETURN x.n ORDER BY x.n") do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [n] -> n end)
      error -> error
    end
  end

  defp write(tow, n, opts \\ []), do: Aerotow.run(tow, @ref, "CREATE (:N {n: $n})", %{n: n}, opts)

  defp peer_write(peer, tow, n, opts \\ []),
    do: PeerTow.call(peer, Aerotow, :run, [tow, @ref, "CREATE (:N {n: $n})", %{n: n}, opts])

  defp flight_pid(tow) do
    [{pid, _}] = Registry.lookup(Instance.fetch!(tow).registry, @ref)
    pid
  end

  defp plain_store(path) do
    {:ok, store} = Store.new("plain", path)
    store
  end

  # The options of an instance in a peer VM, as TowCase gives them here.
  defp peer_opts(name, dir, store) do
    [
      name: name,
      dir: dir,
      stores: [{"store", store}],
      default_store: "store",
      scan_interval: nil,
      idle: :infinity,
      sync_interval: 3_600_000,
      timing: @long
    ]
  end

  describe "the holder is killed with unshipped log" do
    @tag timeout: 300_000
    test "after ttl + grace another instance launches from what was shipped: none of the sync: :commit writes are gone, only what came after the last pass",
         %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      peer = PeerTow.start()
      a = PeerTow.tow(peer, peer_opts(:aerotow_killed_a, Path.join(dir, "a"), store))

      {:ok, _} = PeerTow.call(peer, Aerotow, :create, [a, @ref, []])
      for n <- 1..3, do: {:ok, 1} = peer_write(peer, a, n, sync: :commit)
      {:ok, 1} = peer_write(peer, a, 4)
      {:ok, %{bytes: bytes}} = PeerTow.call(peer, Aerotow, :sync, [a, @ref])
      assert bytes > 0
      {:ok, 1} = peer_write(peer, a, 5)
      {:ok, 1} = peer_write(peer, a, 6)
      :ok = PeerTow.kill(peer)

      {clock, set} = clock(t0())
      b = tow(Path.join(dir, "b"), stores: [{"store", store}], clock: clock, timing: @long)

      # The dead holder's lease still runs: the glider is aloft elsewhere.
      assert {:error, {:aloft_elsewhere, %{flight: 1}}} = ns(b)

      set.(t0() + @long.ttl + @long.grace)
      seen = ns(b)
      assert Enum.take(seen, 4) == [1, 2, 3, 4]
      assert seen in [[1, 2, 3, 4], [1, 2, 3, 4, 5], [1, 2, 3, 4, 5, 6]]
      assert {:ok, %Lease{n: 2, from: %{flight: 1}}} = Lease.current(plain_store(store), @ref)
    end
  end

  describe "the holder restarts on the same disk" do
    @tag timeout: 300_000
    test "R15: it finds its working copy and carries it into the next flight at once: nothing is lost",
         %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      a_dir = Path.join(dir, "a")
      peer = PeerTow.start()
      # From disk: a memory flight's writes die with its VM.
      a = PeerTow.tow(peer, peer_opts(:aerotow_restarted_a, a_dir, store) ++ [mode: "disk"])

      {:ok, _} = PeerTow.call(peer, Aerotow, :create, [a, @ref, []])
      {:ok, 1} = peer_write(peer, a, 1, sync: :commit)
      {:ok, 1} = peer_write(peer, a, 2)
      {:ok, 1} = peer_write(peer, a, 3)
      :ok = PeerTow.kill(peer)

      listen([[:aerotow, :launch, :start], [:aerotow, :launch, :stop]])

      # The same dir, so the same id; the same time, so the dead flight's
      # lease still runs. Nobody else has taken the glider.
      {clock, _set} = clock(t0())
      again = tow(a_dir, stores: [{"store", store}], clock: clock, timing: @long)

      # Carried as the instance starts, before anybody asks for the glider.
      assert_receive {:telemetry, [:aerotow, :launch, :start], _, %{ref: @ref, intent: :carry}},
                     30_000

      assert_receive {:telemetry, [:aerotow, :launch, :stop], _, %{ref: @ref, flight: 2}}, 30_000
      assert {:ok, %Lease{n: 2, from: %{carried: true}}} = Lease.current(plain_store(store), @ref)
      assert ns(again) == [1, 2, 3]

      # And it is all in the store: another instance sees it once it lands.
      :ok = Aerotow.land(again, @ref)
      b = tow(Path.join(dir, "b"), stores: [{"store", store}], clock: clock, timing: @long)
      assert ns(b) == [1, 2, 3]
    end
  end

  describe "the holder freezes past its lease and wakes" do
    test "R10, R5: its flight is lost, and what it ships lands in its own flight's directory, which nobody restores from",
         %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      stores = [{"store", store}]
      {clock_a, set_a} = clock(t0())
      {clock_b, set_b} = clock(t0())

      a =
        tow(Path.join(dir, "a"),
          stores: stores,
          default_store: "store",
          clock: clock_a,
          timing: @long
        )

      b = tow(Path.join(dir, "b"), stores: stores, clock: clock_b, timing: @long)
      listen([[:aerotow, :lease, :lost]])

      {:ok, _} = Aerotow.create(a, @ref)
      {:ok, 1} = write(a, 1, sync: :commit)
      {:ok, 1} = write(a, 2)

      # Frozen: its flight answers nothing and its clock stands still.
      frozen = flight_pid(a)
      :ok = :sys.suspend(frozen)

      set_b.(t0() + @long.ttl + @long.grace)
      assert ns(b) == [1]
      {:ok, 1} = write(b, 10, sync: :commit)
      :ok = Aerotow.land(b, @ref)
      before = snapshot(plain_store(store))

      # Awake, on a clock that says its lease still holds, it ships.
      :ok = :sys.resume(frozen)
      assert {:ok, %{segments: segments}} = Aerotow.sync(a, @ref)
      assert segments > 0

      late = changed(before, snapshot(plain_store(store)))
      assert late != []
      first = Layout.flight_data(@ref, 1) <> "/"
      assert Enum.all?(late, &String.starts_with?(&1, first))

      # A renewal now is refused: flight 2 exists.
      {:ok, lease} = Lease.read(plain_store(store), @ref, 1)
      assert Lease.renew(plain_store(store), lease, clock_a, @long) == {:error, :lost}

      # Its own clock reaches the deadline: it is lost, and writes nothing more.
      set_a.(t0() + @long.ttl - @long.margin)
      assert {:error, :lost} = write(a, 3)
      assert_receive {:telemetry, [:aerotow, :lease, :lost], _, %{ref: @ref, flight: 1}}, 10_000

      # Every later launch restores flight 2's data, never flight 1's late writes.
      assert ns(b) == [1, 10]
      assert {:ok, %Lease{n: 3, from: %{flight: 2}}} = Lease.current(plain_store(store), @ref)
    end
  end

  describe "two instances launch at once" do
    test "R7, R9: one creates the next flight record, the other finds it aloft elsewhere",
         %{tmp_dir: dir} do
      stores = [{"store", Path.join(dir, "store")}]
      a = tow(Path.join(dir, "a"), stores: stores, default_store: "store")
      b = tow(Path.join(dir, "b"), stores: stores)
      {:ok, _} = Aerotow.create(a, @ref)
      {:ok, 1} = write(a, 1)
      :ok = Aerotow.land(a, @ref)
      {:ok, _} = Aerotow.scan(b, "store")

      results =
        [a, b]
        |> Enum.map(fn tow -> Task.async(fn -> {tow, ns(tow)} end) end)
        |> Enum.map(&Task.await(&1, 60_000))

      assert [{won, [1]}] = Enum.filter(results, fn {_, seen} -> seen == [1] end)
      [{_lost, refused}] = Enum.reject(results, fn {tow, _} -> tow == won end)
      won_id = Instance.fetch!(won).id
      assert {:error, {:aloft_elsewhere, %{holder: ^won_id, flight: 2}}} = refused
      assert Lease.flights(plain_store(Path.join(dir, "store")), @ref) == {:ok, [1, 2]}
    end
  end

  describe "the store is unreachable" do
    setup %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      on_exit(fn -> writable(store, true) end)
      %{store: store}
    end

    test "R14: renewals fail until expires_at - margin, the flight is lost with its copy kept in orphans/, and when the store is back the copy is carried into the next flight",
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
      {:ok, _} = Aerotow.create(a, @ref)
      {:ok, 1} = write(a, 1, sync: :commit)

      # Written once the store is away, so nothing ships them.
      writable(store, false)
      {:ok, 1} = write(a, 2)
      {:ok, 1} = write(a, 3)

      # Past the time to renew: the renewal fails, and the flight goes on.
      set.(t0() + div(@short.ttl, 3) + 1)
      refute_receive {:telemetry, [:aerotow, :lease, :lost], _, _}, 1_000
      assert {:ok, [%{ref: @ref, state: :aloft}]} = Aerotow.aloft(a)

      # At expires_at - margin it is lost, and its copy kept whole.
      set.(t0() + @short.ttl - @short.margin)
      assert_receive {:telemetry, [:aerotow, :lease, :lost], _, %{ref: @ref, flight: 1}}, 10_000

      assert_receive {:telemetry, [:aerotow, :flight, :orphaned], _, %{ref: @ref, path: kept}},
                     10_000

      assert {:ok, [%{ref: @ref, store: "store", flight: 1, path: ^kept, bytes: bytes}]} =
               Aerotow.orphans(a)

      assert bytes > 0

      # The store is back, and nobody took off meanwhile.
      writable(store, true)
      assert ns(a) == [1, 2, 3]
      assert {:ok, []} = Aerotow.orphans(a)
      assert {:ok, %Lease{n: 2, from: %{carried: true}}} = Lease.current(plain_store(store), @ref)

      :ok = Aerotow.land(a, @ref)
      b = tow(Path.join(dir, "b"), stores: [{"store", store}], clock: clock, timing: @short)
      assert ns(b) == [1, 2, 3]
    end
  end

  describe "a card or record in the store is garbage" do
    test "R6: it is refused where it is read; a glider with no readable flight record does not launch",
         %{tmp_dir: dir} do
      path = Path.join(dir, "store")
      a = tow(Path.join(dir, "a"), stores: [{"store", path}], default_store: "store")
      {:ok, _} = Aerotow.create(a, @ref)
      :ok = Aerotow.land(a, @ref)
      {:ok, _} = Aerotow.create(a, "other/g")
      :ok = Aerotow.land(a, "other/g")

      store = plain_store(path)
      :ok = Store.put(store, Layout.flight_record(@ref, 1), "{\"format\": 1, \"ref\": [")
      :ok = Store.put(store, Layout.card("other/g"), "not a card")
      before = snapshot(store)

      b = tow(Path.join(dir, "b"), stores: [{"store", path}])
      assert {:ok, %{seen: 2}} = Aerotow.scan(b, "store")
      assert {:ok, %{gliders: [%{ref: @ref}]}} = Aerotow.gliders(b)
      assert {:error, reason} = ns(b)
      assert is_binary(reason)
      assert Aerotow.query(b, "other/g", "STATS") == {:error, :not_found}
      assert snapshot(store) == before
      assert {:ok, []} = Aerotow.aloft(b)
    end
  end

  describe "the catalog file is lost" do
    test "R2: scan/2 rebuilds it from the stores", %{tmp_dir: dir} do
      stores = [{"store", Path.join(dir, "store")}]
      a_dir = Path.join(dir, "a")
      a = tow(a_dir, name: name("catalog"), stores: stores, default_store: "store")
      {:ok, _} = Aerotow.create(a, @ref, tags: ["code"])
      {:ok, 1} = write(a, 1)
      :ok = stop_supervised!(a)

      for file <- Path.wildcard(Path.join(a_dir, "catalog.gldb*")), do: File.rm_rf!(file)

      again = tow(a_dir, stores: stores)
      assert {:ok, %{seen: 1}} = Aerotow.scan(again, "store")
      assert {:ok, %{gliders: [%{ref: @ref, tags: ["code"]}]}} = Aerotow.gliders(again)
      assert ns(again) == [1]
    end
  end

  describe "a bucket has no conditional writes" do
    test "add_store reports cas: false and refuses to write there unless single_writer: true",
         %{tmp_dir: dir} do
      {fake, s3} = s3()
      FakeS3.conditional(fake, :ignore)
      a = tow(Path.join(dir, "a"))

      assert {:ok, %{cas: false}} = Aerotow.add_store(a, "assets", "s3://graphs/gliders", s3)
      assert Aerotow.create(a, @ref, store: "assets") == {:error, :no_cas}

      assert {:ok, %{cas: false}} =
               Aerotow.add_store(a, "mine", "s3://graphs/mine", [single_writer: true] ++ s3)

      assert {:ok, _} = Aerotow.create(a, @ref, store: "mine")
      {:ok, 1} = write(a, 1)
      :ok = Aerotow.land(a, @ref)
      assert ns(a) == [1]
    end
  end

  # Every directory of a dir store made read-only, or writable again.
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
