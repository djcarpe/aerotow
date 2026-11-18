defmodule Aerotow.FlightTest do
  # Not async: the first store in a VM loads code and makes atoms, and
  # Aerotow.CardTest counts the VM's atoms while it runs.
  use ExUnit.Case, async: false

  import Aerotow.FlightCase

  alias Aerotow.{Card, Catalog, Flight, Lease, StallStore, Store}
  alias Aerotow.Flight.Copy
  alias Aerotow.Store.Layout

  doctest Aerotow.Flight.Copy

  @moduletag :tmp_dir
  # Failing and stalling stores are reported as warnings; they are expected here.
  @moduletag :capture_log

  @ref "engineering/code"
  @ttl 30_000
  @margin 5_000
  @grace 5_000

  setup %{tmp_dir: dir} do
    {clock, set} = clock()
    a = instance(dir, "a", clock: clock)
    store = dir_store(Path.join(dir, "store"), [a])
    %{dir: dir, clock: clock, set: set, a: a, store: store}
  end

  # A second instance on the same store: its own dir, catalog and registry.
  defp second(%{dir: dir, clock: clock, store: store}, opts \\ []) do
    b = instance(dir, "b", [clock: clock] ++ opts)
    :ok = Catalog.put_store(b.catalog, Store.public(store))
    b
  end

  # The store wrapped so the test can make it fail or stall.
  defp stalling(store) do
    ctl = start_supervised!({StallStore, watcher: self()})
    {StallStore.wrap(store, ctl), ctl}
  end

  defp record(store, n, ref \\ @ref) do
    {:ok, lease} = Lease.read(store, ref, n)
    lease
  end

  defp working(instance, store, ref \\ @ref), do: Copy.path(instance, store, ref)

  defp renew_due(lease), do: lease.expires_at - @ttl + div(@ttl, 3)
  defp deadline(lease), do: lease.expires_at - @margin

  # Kills a flight outright, and waits until glider has let go of its copy
  # at `path`: once no process holds the handle (a checkout hands it to the
  # caller, so every process collects its garbage) and the VM has finished
  # with the dead process, which it does after its monitors have fired.
  defp kill(pid, path) do
    Process.exit(pid, :kill)
    assert :killed = down(pid)
    released(path, System.monotonic_time(:millisecond) + 10_000)
  end

  defp released(path, until) do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)

    cond do
      not File.exists?(path <> ".lock") -> :ok
      System.monotonic_time(:millisecond) > until -> flunk("#{path} is still open")
      true -> released(path, until)
    end
  end

  # Corrupts the base flight n shipped, so it restores and does not open.
  defp corrupt_base(store, n) do
    {url, _opts} = Store.replica(store, Layout.flight_data(@ref, n))
    [db | _] = Path.wildcard(Path.join(url, "*/base/*/db"))
    File.write!(db, "not a database")
  end

  # ------------------------------------------------------------------ getting up

  describe "1: create" do
    test "takes flight 1, writes the card and ships a whole base before anything is checked out",
         %{a: a, store: store, dir: dir} do
      {:ok, pid} = create(a, store, @ref, description: "the code graph")

      # Before this test has touched the flight, the store has all of it.
      assert {:ok, [1]} = Lease.flights(store, @ref)
      assert {:ok, %Card{description: "the code graph", flight: 1}} = Store.read_card(store, @ref)
      assert %Lease{shipped: %{bases: bases}, landed: false} = record(store, 1)
      assert bases >= 1
      assert shipped_ns(store, @ref, 1, dir) == []
      assert Flight.info(pid).state == :aloft
    end

    test "a second instance launches it once this one has landed", ctx do
      %{a: a, store: store} = ctx
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      :ok = Flight.land(pid)

      b = second(ctx)
      {:ok, pid_b} = launch(b, store, @ref)
      assert ns(pid_b) == [1]
      assert Flight.info(pid_b).flight == 2
    end

    test "a ref that already has a flight is :exists and nothing in the store changes", ctx do
      %{a: a, store: store} = ctx
      {:ok, pid} = create(a, store, @ref)
      before = snapshot(store)

      assert {:error, :exists} = create(a, store, @ref)
      assert {:error, :exists} = create(second(ctx), store, @ref)

      :ok = Flight.land(pid)
      landed = snapshot(store)
      assert {:error, :exists} = create(a, store, @ref)
      assert snapshot(store) == landed
      assert Map.keys(before) -- Map.keys(landed) == []
    end
  end

  describe "2: launch (R12)" do
    test "R12: restores the newest state an earlier flight shipped, and answers with exactly that",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      :ok = Flight.land(pid)

      {:ok, pid} = launch(a, store, @ref)
      {:ok, _} = write(pid, 2)
      :ok = Flight.land(pid)

      # Flight 3 only reads, and ships nothing.
      {:ok, pid} = launch(a, store, @ref)
      assert ns(pid) == [1, 2]
      :ok = Flight.land(pid)

      {:ok, pid} = launch(a, store, @ref)
      assert ns(pid) == [1, 2]
      assert %Lease{from: %{flight: 2}} = record(store, 4)
    end

    test "a glider with no flight records is :not_found, and nothing is written",
         %{a: a, store: store} do
      before = snapshot(store)
      assert {:error, :not_found} = launch(a, store, "nobody/here")
      assert snapshot(store) == before
      assert Registry.lookup(a.registry, "nobody/here") == []
    end

    test "a glider aloft on another instance is {:aloft, lease}, and no flight record is made",
         ctx do
      %{a: a, store: store} = ctx
      {:ok, _pid} = create(a, store, @ref)
      before = snapshot(store)

      b = second(ctx)
      assert {:error, {:aloft, %Lease{n: 1, holder: holder}}} = launch(b, store, @ref)
      assert holder == a.id
      assert {:ok, [1]} = Lease.flights(store, @ref)
      assert snapshot(store) == before
    end
  end

  describe "3: adopt" do
    test "makes a glider from a .gldb file, which is left as it was, and ships it before use",
         %{a: a, store: store, dir: dir} do
      source = Path.join([dir, "outside", "old.gldb"])
      File.mkdir_p!(Path.dirname(source))
      {:ok, db} = Glider.open(source)
      for n <- 1..3, do: {:ok, _} = Glider.run(db, "CREATE (:N {n: $n})", n: n)
      :ok = Glider.close(db)
      original = Map.new(files_under(Path.dirname(source)), &{&1, File.read!(&1)})

      {:ok, card} = Card.new(@ref, tags: ["adopted"])
      {:ok, pid} = fly(a, store, @ref, {:adopt, card, source})

      # Its contents are in the store before anything has been checked out.
      assert shipped_ns(store, @ref, 1, dir) == [1, 2, 3]
      assert Map.new(files_under(Path.dirname(source)), &{&1, File.read!(&1)}) == original

      # From then on it is a glider like any other.
      assert ns(pid) == [1, 2, 3]
      {:ok, _} = write(pid, 4)
      :ok = Flight.land(pid)
      {:ok, pid} = launch(a, store, @ref)
      assert ns(pid) == [1, 2, 3, 4]
      assert {:ok, %Card{tags: ["adopted"], nodes: 4}} = Store.read_card(store, @ref)
    end
  end

  describe "4: a launch that fails" do
    test "leaves no working copy and no registry entry, and lands the record it took",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      :ok = Flight.land(pid)
      corrupt_base(store, 1)

      assert {:error, {:launch, _reason}} = launch(a, store, @ref)
      refute Copy.exists?(working(a, store))
      assert Registry.lookup(a.registry, @ref) == []

      assert %Lease{landed: true, shipped: nil, from: %{flight: 1}} = record(store, 2)

      # The next taker does not wait out a lease: it takes flight 3 at once.
      assert {:error, {:launch, _}} = launch(a, store, @ref)
      assert %Lease{landed: true} = record(store, 3)
    end
  end

  describe "5: file stores" do
    test "create and launch open <root>/<ref>.gldb in place, with no flight records",
         %{a: a, dir: dir} do
      root = Path.join(dir, "disk")
      disk = file_store(root, [a])

      {:ok, pid} = create(a, disk, @ref, description: "on this disk")
      assert File.regular?(Path.join(root, @ref <> ".gldb"))
      assert Flight.info(pid).flight == nil
      {:ok, _} = write(pid, 1)
      assert {:ok, %{bases: 0}} = Flight.sync(pid)
      :ok = Flight.land(pid)

      assert File.regular?(Path.join(root, @ref <> ".gldb"))
      assert {:ok, %Card{nodes: 1, description: "on this disk"}} = Store.read_card(disk, @ref)
      refute File.exists?(Path.join(a.dir, "flights"))

      {:ok, pid} = launch(a, disk, @ref)
      assert ns(pid) == [1]
    end

    test "a second flight of the same file, from another instance, says the file is locked",
         ctx do
      %{a: a, dir: dir} = ctx
      root = Path.join(dir, "disk")
      disk = file_store(root, [a])
      {:ok, _pid} = create(a, disk, @ref)

      b = second(ctx)
      :ok = Catalog.put_store(b.catalog, Store.public(disk))
      assert {:error, {:launch, reason}} = launch(b, disk, @ref)
      assert reason =~ "locked"
      assert Registry.lookup(b.registry, @ref) == []
    end

    test "a launch of a file that is not there is :not_found", %{a: a, dir: dir} do
      disk = file_store(Path.join(dir, "disk"), [a])
      assert {:error, :not_found} = launch(a, disk, @ref)
    end
  end

  # ------------------------------------------------------------------ aloft

  describe "6: statements from many processes" do
    test "readers and writers through run/4 and checkout/checkin all complete, and every write is there",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)

      writers =
        for i <- 1..40 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              {:ok, {:ok, _}} = write(pid, i)
            else
              {:ok, db, token} = Flight.checkout(pid, :write)
              {:ok, _} = Glider.run(db, "CREATE (:N {n: $n})", n: i)
              :ok = Flight.checkin(pid, token, true)
            end

            ns(pid)
          end)
        end

      readers = for _ <- 1..20, do: Task.async(fn -> ns(pid) end)

      Enum.each(Task.await_many(writers ++ readers, 60_000), &assert(is_list(&1)))
      assert ns(pid) == Enum.to_list(1..40)
      assert Flight.info(pid).checked_out == 0
    end

    test "a long statement in one process delays neither a lease renewal nor another caller's info/1",
         ctx do
      %{dir: dir, clock: clock, set: set, store: store} = ctx
      a = instance(dir, "quick", clock: clock, sync_interval: 20)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      listen([[:aerotow, :lease, :renewed]])
      {:ok, pid} = create(a, store, @ref)
      test = self()

      # A caller holds the handle inside a transaction, and does not let go.
      holder =
        spawn(fn ->
          {:ok, db, token} = Flight.checkout(pid, :write)

          Glider.transaction(db, fn ->
            {:ok, _} = Glider.run(db, "CREATE (:N {n: 1})")
            send(test, :inside)

            receive do
              :done -> :ok
            end
          end)

          Flight.checkin(pid, token, true)
          send(test, :out)
        end)

      assert_receive :inside, 5_000
      lease = record(store, 1)
      set.(renew_due(lease))

      assert_receive {:telemetry, [:aerotow, :lease, :renewed], %{expires_at: expires},
                      %{ref: @ref}},
                     5_000

      assert expires > lease.expires_at
      assert %{checked_out: 1, state: :aloft} = Flight.info(pid)

      send(holder, :done)
      assert_receive :out, 5_000
      assert ns(pid) == [1]
    end
  end

  describe "7: a caller that dies" do
    test "has its checkout returned, inside a transaction or not, and the flight answers and lands",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      test = self()

      in_transaction =
        spawn(fn ->
          {:ok, db, _token} = Flight.checkout(pid, :write)

          Glider.transaction(db, fn ->
            {:ok, _} = Glider.run(db, "CREATE (:N {n: 2})")
            send(test, :inside)

            receive do
              :never -> :ok
            end
          end)
        end)

      plain =
        spawn(fn ->
          {:ok, _db, _token} = Flight.checkout(pid, :read)
          send(test, :checked_out)

          receive do
            :never -> :ok
          end
        end)

      assert_receive :inside, 5_000
      assert_receive :checked_out, 5_000
      Process.exit(in_transaction, :kill)
      Process.exit(plain, :kill)

      # The dead caller's transaction is rolled back, and the handle answers.
      assert ns(pid) == [1]
      {:ok, _} = write(pid, 3)
      assert :ok = Flight.land(pid)
      assert :normal = down(pid)
    end
  end

  describe "8: shipping" do
    test "after a write the store has it within sync_interval, without anybody asking", ctx do
      %{dir: dir, clock: clock, store: store} = ctx
      a = instance(dir, "quick", clock: clock, sync_interval: 20)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {:ok, pid} = create(a, store, @ref)
      listen([[:aerotow, :sync, :stop]])

      {:ok, _} = write(pid, 1)

      assert_receive {:telemetry, [:aerotow, :sync, :stop], %{segments: segments},
                      %{ref: @ref, flight: 1}},
                     5_000

      assert segments >= 1
      assert shipped_ns(store, @ref, 1, dir) == [1]
      refute Flight.info(pid).dirty
    end

    test "sync/2 ships now", %{a: a, store: store, dir: dir} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      assert Flight.info(pid).dirty

      assert {:ok, %{segments: segments, generation: generation}} = Flight.sync(pid)
      assert segments >= 1
      assert is_binary(generation)
      assert shipped_ns(store, @ref, 1, dir) == [1]
      refute Flight.info(pid).dirty
    end

    test "a flight that only read ships nothing, and its record points at what it restored from",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      :ok = Flight.land(pid)

      {:ok, pid} = launch(a, store, @ref)
      assert ns(pid) == [1]
      assert {:ok, %{bases: 0, segments: 0}} = Flight.sync(pid)
      :ok = Flight.land(pid)

      assert {:ok, %{objects: []}} = Store.list(store, Layout.flight_data(@ref, 2) <> "/")
      assert %Lease{landed: true, shipped: nil, from: %{flight: 1}} = record(store, 2)
    end
  end

  describe "9: R5" do
    test "R5: across creates, writes, syncs and landings a flight writes only its card, its record and its own directory",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      :ok = Flight.land(pid)

      before = snapshot(store)
      {:ok, pid} = launch(a, store, @ref)
      {:ok, _} = write(pid, 2)
      {:ok, _} = Flight.sync(pid)
      {:ok, _} = write(pid, 3)
      {:ok, _} = Flight.sync(pid)
      {:ok, _} = write(pid, 4)
      :ok = Flight.land(pid)
      later = snapshot(store)

      changed = changed(before, later)
      own = Layout.flight_data(@ref, 2) <> "/"
      assert Layout.card(@ref) in changed
      assert Layout.flight_record(@ref, 2) in changed
      assert Enum.any?(changed, &String.starts_with?(&1, own))

      assert Enum.reject(changed, fn key ->
               key in [Layout.card(@ref), Layout.flight_record(@ref, 2)] or
                 String.starts_with?(key, own)
             end) == []

      # Nothing of flight 1 was touched.
      for {key, body} <- before,
          String.starts_with?(key, Layout.flights_prefix(@ref)),
          not String.starts_with?(key, own) do
        assert Map.fetch!(later, key) == body
      end
    end
  end

  describe "10: R11" do
    test "R11: once the clock reaches expires_at - margin, a write checkout is refused",
         %{a: a, store: store, set: set} do
      {:ok, pid} = create(a, store, @ref)
      lease = record(store, 1)

      set.(deadline(lease) - 1)
      assert {:ok, _db, token} = Flight.checkout(pid, :write)
      :ok = Flight.checkin(pid, token, false)

      set.(deadline(lease))
      assert {:error, :lost} = Flight.checkout(pid, :write)
      assert {:shutdown, :lost} = down(pid)
    end

    test "R11: once the clock reaches expires_at - margin, no shipping pass starts",
         %{a: a, store: store, set: set} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      before = snapshot(store)

      set.(deadline(record(store, 1)))
      assert {:error, :lost} = Flight.sync(pid)
      assert {:shutdown, :lost} = down(pid)
      assert snapshot(store) == before
    end

    test "R11: a write with sync: :commit whose ship finished past the margin is {:error, :lost}",
         %{a: a, store: store, set: set, dir: dir} do
      {stall, ctl} = stalling(store)
      {:ok, pid} = create(a, stall, @ref)
      lease = record(store, 1)
      test = self()

      StallStore.set(ctl, :replica, :block)
      spawn(fn -> send(test, {:committed, write(pid, 1, sync: :commit)}) end)
      assert_receive {:stalled, :replica, _}, 5_000

      set.(deadline(lease))
      StallStore.release(ctl)

      assert_receive {:committed, {:error, :lost}}, 10_000
      assert {:shutdown, :lost} = down(pid)
      # It did ship: what it would not say is that it shipped in time.
      assert shipped_ns(store, @ref, 1, dir) == [1]
    end

    test "R11: a write with sync: :commit shipped in time is acknowledged",
         %{a: a, store: store, dir: dir} do
      {:ok, pid} = create(a, store, @ref)
      assert {:ok, {:ok, _}} = write(pid, 1, sync: :commit)
      assert shipped_ns(store, @ref, 1, dir) == [1]
    end
  end

  describe "11: a slow store" do
    test "delays no checkout or info/1, and a stuck renewal does not keep the flight up past its deadline",
         ctx do
      %{dir: dir, clock: clock, set: set, store: store} = ctx
      a = instance(dir, "quick", clock: clock, sync_interval: 20)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {stall, ctl} = stalling(store)
      listen([[:aerotow, :lease, :lost]])
      {:ok, pid} = create(a, stall, @ref)
      {:ok, _} = write(pid, 1)
      lease = record(store, 1)

      StallStore.set(ctl, [:put, :replica], :block)
      set.(renew_due(lease))
      assert_receive {:stalled, :put, key}, 5_000
      assert key == Layout.flight_record(@ref, 1)

      # The renewal is stuck in the store; the flight answers at once.
      assert {:ok, _db, token} = Flight.checkout(pid, :read, 1_000)
      :ok = Flight.checkin(pid, token, false)
      assert %{state: :aloft} = Flight.info(pid)

      set.(deadline(lease))

      assert_receive {:telemetry, [:aerotow, :lease, :lost], _, %{ref: @ref, reason: :deadline}},
                     5_000

      assert {:shutdown, :lost} = down(pid)
      StallStore.release(ctl)
    end
  end

  # ------------------------------------------------------------------ coming down

  describe "12: landing" do
    test "ships what is left, writes the card and the record, removes the copy, and goes",
         ctx do
      %{a: a, store: store, dir: dir} = ctx
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = Flight.run(pid, :write, &Glider.run(&1, "INDEX ON :N(n)"))
      for n <- 1..3, do: {:ok, _} = write(pid, n)
      {:ok, _} = Flight.run(pid, :write, &Glider.run(&1, "CREATE (:M)-[:R]->(:M)"))
      path = working(a, store)
      assert Copy.exists?(path)

      assert :ok = Flight.land(pid)
      assert :normal = down(pid)

      assert {:ok, card} = Store.read_card(store, @ref)
      assert %Card{nodes: 5, edges: 1, flight: 1} = card
      assert [%{name: "M", count: 2}, %{name: "N", count: 3}] = card.labels
      assert [%{name: "R", count: 1}] = card.types
      assert [%{count: 3}] = card.indexes
      assert is_binary(card.generation) and is_integer(card.position)

      assert %Lease{landed: true, shipped: %{generation: generation, position: position}} =
               record(store, 1)

      assert {generation, position} == {card.generation, card.position}
      assert files_under(Path.join(a.dir, "flights")) == []
      assert Registry.lookup(a.registry, @ref) == []
      assert {:ok, %Card{aloft: false, nodes: 5}} = Catalog.card(a.catalog, @ref)

      assert shipped_ns(store, @ref, 1, dir) == [1, 2, 3]
      {:ok, pid_b} = launch(second(ctx), store, @ref)
      assert ns(pid_b) == [1, 2, 3]
    end

    test "a flight lands once idle has passed with nothing checked out", ctx do
      %{dir: dir, clock: clock, set: set, store: store} = ctx
      a = instance(dir, "idle", clock: clock, idle: 20_000)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      %{last_used: used} = Flight.info(pid)

      set.(used + 20_000)
      assert %{state: :landing} = Flight.info(pid)
      assert :normal = down(pid)
      assert %Lease{landed: true} = record(store, 1)
    end
  end

  describe "13: landing waits and refuses" do
    test "landing waits for a checkout out, and a checkout asked for meanwhile is :landing",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _db, token} = Flight.checkout(pid, :read)
      test = self()

      spawn(fn -> send(test, {:landed, Flight.land(pid)}) end)
      wait_for(fn -> Flight.info(pid).state == :landing end)

      assert {:error, :landing} = Flight.checkout(pid, :read)
      assert {:error, :landing} = Flight.checkout(pid, :write)
      refute_received {:landed, _}

      :ok = Flight.checkin(pid, token, false)
      assert_receive {:landed, :ok}, 10_000
    end

    test "a pinned flight does not land for being idle; land/2 lands it anyway", ctx do
      %{dir: dir, clock: clock, set: set, store: store} = ctx
      a = instance(dir, "idle", clock: clock, idle: 20_000)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {:ok, card} = Card.new(@ref)
      {:ok, pid} = fly(a, store, @ref, {:create, card}, pin: true)
      %{last_used: used, pinned: true} = Flight.info(pid)

      set.(used + 24_000)
      assert %{state: :aloft} = Flight.info(pid)

      :ok = Flight.pin(pid, false)
      :ok = Flight.pin(pid, true)
      assert %{state: :aloft} = Flight.info(pid)
      assert :ok = Flight.land(pid)
    end
  end

  describe "14: a last ship that fails" do
    test "keeps the flight aloft and answering, and it lands when the store is back", ctx do
      %{dir: dir, clock: clock, store: store} = ctx
      a = instance(dir, "quick", clock: clock, sync_interval: 20)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {stall, ctl} = stalling(store)
      listen([[:aerotow, :land, :exception]])
      {:ok, pid} = create(a, stall, @ref)
      path = working(a, store)

      StallStore.set(ctl, [:put, :replica], :fail)
      {:ok, _} = write(pid, 1)
      test = self()
      spawn(fn -> send(test, {:landed, Flight.land(pid)}) end)

      assert_receive {:telemetry, [:aerotow, :land, :exception], _, %{ref: @ref}}, 5_000
      assert Copy.exists?(path)
      assert {:ok, {:ok, _}} = write(pid, 2)
      assert ns(pid) == [1, 2]
      refute_received {:landed, _}

      StallStore.release(ctl)
      assert_receive {:landed, :ok}, 10_000
      assert :normal = down(pid)
      refute Copy.exists?(path)

      {:ok, pid} = launch(a, store, @ref)
      assert ns(pid) == [1, 2]
    end
  end

  describe "15: lost (R10, R14)" do
    test "R10, R14: renewals that fail until the deadline lose the flight, and a copy with unshipped log is kept aside",
         ctx do
      %{dir: dir, clock: clock, set: set, store: store} = ctx
      a = instance(dir, "quick", clock: clock, sync_interval: 20)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {stall, ctl} = stalling(store)
      listen([[:aerotow, :lease, :lost], [:aerotow, :flight, :orphaned]])
      {:ok, pid} = create(a, stall, @ref)
      lease = record(store, 1)

      StallStore.set(ctl, [:put, :replica], :fail)
      {:ok, _} = write(pid, 1)
      {:ok, _} = write(pid, 2)
      set.(renew_due(lease))
      assert %{state: :aloft} = Flight.info(pid)
      before = snapshot(store)

      set.(deadline(lease))
      assert_receive {:telemetry, [:aerotow, :lease, :lost], _, %{ref: @ref, flight: 1}}, 5_000

      assert_receive {:telemetry, [:aerotow, :flight, :orphaned], _, %{ref: @ref, path: orphan}},
                     5_000

      assert {:shutdown, :lost} = down(pid)
      assert snapshot(store) == before

      assert orphan == Path.join([a.dir, "orphans", "store", @ref <> ".1.gldb"])
      assert File.regular?(Copy.marker_path(orphan))
      assert {:ok, %{store: "store", ref: @ref, flight: 1}} = Copy.read_marker(orphan)
      refute Copy.exists?(working(a, store))
      assert ns_in(orphan) == [1, 2]
      assert Registry.lookup(a.registry, @ref) == []
    end

    test "R10: a renewal that finds a higher flight loses the flight, and a copy with nothing unshipped is deleted",
         ctx do
      %{dir: dir, clock: clock, set: set, store: store} = ctx
      a = instance(dir, "quick", clock: clock, sync_interval: 20)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      listen([[:aerotow, :lease, :lost], [:aerotow, :flight, :orphaned]])
      {:ok, pid} = create(a, store, @ref)
      lease = record(store, 1)

      newer = %Lease{lease | n: 2, holder: String.duplicate("b", 32)}
      :ok = Store.put(store, Layout.flight_record(@ref, 2), Lease.encode(newer))
      set.(renew_due(lease))

      assert_receive {:telemetry, [:aerotow, :lease, :lost], _, %{ref: @ref, reason: :lease}},
                     5_000

      assert {:shutdown, :lost} = down(pid)
      refute_received {:telemetry, [:aerotow, :flight, :orphaned], _, _}
      refute Copy.exists?(working(a, store))
      assert files_under(Path.join(a.dir, "orphans")) == []
    end

    test "R10: a renewal that finds the record no longer this flight's loses the flight", ctx do
      %{dir: dir, clock: clock, set: set, store: store} = ctx
      a = instance(dir, "quick", clock: clock, sync_interval: 20)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {:ok, pid} = create(a, store, @ref)
      lease = record(store, 1)

      taken = %Lease{lease | holder: String.duplicate("c", 32)}
      :ok = Store.put(store, Layout.flight_record(@ref, 1), Lease.encode(taken))
      set.(renew_due(lease))

      assert {:shutdown, :lost} = down(pid)
    end

    test "R10: a lost flight ships nothing from that instant, however long a stuck pass takes to return",
         %{a: a, store: store, set: set} do
      {stall, ctl} = stalling(store)
      {:ok, pid} = create(a, stall, @ref)
      lease = record(store, 1)
      {:ok, _} = write(pid, 1)
      test = self()

      StallStore.set(ctl, :replica, :block)
      spawn(fn -> send(test, {:synced, Flight.sync(pid)}) end)
      assert_receive {:stalled, :replica, _}, 5_000
      before = snapshot(store)

      set.(deadline(lease))
      assert %{state: :lost} = Flight.info(pid)
      assert_receive {:synced, {:error, :lost}}, 5_000
      assert {:shutdown, :lost} = down(pid)

      StallStore.release(ctl)
      _ = :sys.get_state(ctl)
      assert snapshot(store) == before
      assert ns_in(Copy.orphan_path(a, store, @ref, 1)) == [1]
    end
  end

  describe "16: killed" do
    test "a flight killed while dirty leaves its copy, its marker and its lease, and nothing half-written",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      lease = record(store, 1)
      before = snapshot(store)

      kill(pid, working(a, store))

      path = working(a, store)
      assert File.regular?(path)
      assert {:ok, %{flight: 1, ref: @ref, store: "store"}} = Copy.read_marker(path)
      assert record(store, 1) == lease
      assert snapshot(store) == before
      assert ns_in(path) == [1]
    end
  end

  describe "17: carry (R15)" do
    test "R15: a copy whose flight is the newest is carried into the next flight, at once, and shipped whole",
         ctx do
      %{a: a, store: store, dir: dir} = ctx
      listen([[:aerotow, :sync, :stop]])
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      {:ok, _} = write(pid, 2)
      kill(pid, working(a, store))
      path = working(a, store)

      # The clock has not moved: flight 1 is still active, and is this
      # instance's own, so it is taken over at once.
      {:ok, pid} = fly(a, store, @ref, {:carry, path})
      assert %{flight: 2} = Flight.info(pid)
      assert %Lease{from: %{carried: true}} = record(store, 2)
      assert_receive {:telemetry, [:aerotow, :sync, :stop], %{bases: bases}, %{flight: 2}}, 5_000
      assert bases >= 1
      assert shipped_ns(store, @ref, 2, dir) == [1, 2]

      :ok = Flight.land(pid)
      {:ok, pid} = launch(second(ctx), store, @ref)
      assert ns(pid) == [1, 2]
    end

    test "R15: a copy kept in orphans/ is carried from there", ctx do
      %{a: a, store: store, set: set, dir: dir} = ctx
      {stall, ctl} = stalling(store)
      {:ok, pid} = create(a, stall, @ref)
      {:ok, _} = write(pid, 1)
      StallStore.set(ctl, [:put, :replica], :fail)
      set.(deadline(record(store, 1)))
      assert %{state: :lost} = Flight.info(pid)
      {:shutdown, :lost} = down(pid)
      StallStore.release(ctl)

      orphan = Copy.orphan_path(a, store, @ref, 1)
      {:ok, pid} = fly(a, store, @ref, {:carry, orphan})
      refute Copy.exists?(orphan)
      {:ok, _} = Flight.sync(pid)
      assert shipped_ns(store, @ref, 2, dir) == [1]
    end

    test "R15: a copy whose flight is not the newest is {:launch, :superseded}, and is left as it was",
         ctx do
      %{a: a, store: store, set: set} = ctx
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      lease = record(store, 1)
      kill(pid, working(a, store))

      path = working(a, store)
      copy = Map.new(files_under(Path.dirname(path)), &{&1, File.read!(&1)})

      # Another instance waits out the lease and moves on.
      set.(lease.expires_at + @grace)
      {:ok, pid_b} = launch(second(ctx), store, @ref)
      :ok = Flight.land(pid_b)

      assert {:error, {:launch, :superseded}} = fly(a, store, @ref, {:carry, path})
      assert Map.new(files_under(Path.dirname(path)), &{&1, File.read!(&1)}) == copy
      assert {:ok, [1, 2]} = Lease.flights(store, @ref)
    end

    test "a launch that finds a working copy where its own would go refuses, and leaves it",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      kill(pid, working(a, store))
      path = working(a, store)

      assert {:error, {:launch, {:copy_exists, ^path}}} = launch(a, store, @ref)
      assert ns_in(path) == [1]
    end
  end

  # ------------------------------------------------------------------ everything else

  describe "18: the catalog" do
    test "says aloft while aloft, and update_card/2 and describe/1 change the card in the store and the catalog",
         %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref, description: "first")
      assert {:ok, %Card{aloft: true, description: "first"}} = Catalog.card(a.catalog, @ref)

      assert {:ok, %Card{description: "second", tags: ["code"]}} =
               Flight.update_card(pid, description: "second", tags: ["code"])

      assert {:ok, %Card{description: "second", tags: ["code"]}} = Store.read_card(store, @ref)
      assert {:ok, %Card{description: "second", aloft: true}} = Catalog.card(a.catalog, @ref)

      {:ok, _} = write(pid, 1)
      {:ok, _} = write(pid, 2)
      assert {:ok, %Card{nodes: 2}} = Flight.describe(pid)

      assert {:ok, %Card{nodes: 2, labels: [%{name: "N", count: 2}]}} =
               Store.read_card(store, @ref)

      assert {:ok, %Card{nodes: 2}} = Catalog.card(a.catalog, @ref)
      assert %Card{nodes: 2, description: "second"} = Flight.card(pid)
    end

    test "a card field a flight owns cannot be set through update_card/2", %{a: a, store: store} do
      {:ok, pid} = create(a, store, @ref)
      before = Store.read_card(store, @ref)

      for changes <- [[nodes: 5], [flight: 9], [generation: "ab"], [created_at: 1], [schema: "x"]] do
        assert {:error, reason} = Flight.update_card(pid, changes)
        assert is_binary(reason)
      end

      assert Store.read_card(store, @ref) == before
    end
  end

  describe "19: telemetry" do
    test "launch, sync and land are spans with the metadata the design lists",
         %{a: a, store: store} do
      events =
        for name <- [:launch, :sync, :land],
            phase <- [:start, :stop, :exception],
            do: [:aerotow, name, phase]

      listen(events)
      {:ok, pid} = create(a, store, @ref)
      {:ok, _} = write(pid, 1)
      {:ok, _} = Flight.sync(pid)
      :ok = Flight.land(pid)

      assert_received {:telemetry, [:aerotow, :launch, :start], %{system_time: _},
                       %{ref: @ref, store: "store", mode: "disk"}}

      assert_received {:telemetry, [:aerotow, :launch, :stop], %{duration: _, bytes: bytes},
                       %{ref: @ref, store: "store", flight: 1, mode: "disk", from: nil}}

      assert bytes > 0

      assert_received {:telemetry, [:aerotow, :sync, :start], _, %{ref: @ref, flight: 1}}

      assert_received {:telemetry, [:aerotow, :sync, :stop],
                       %{duration: _, bytes: _, bases: _, segments: _, lag: _},
                       %{ref: @ref, store: "store", flight: 1, mode: "disk"}}

      assert_received {:telemetry, [:aerotow, :land, :start], _, %{ref: @ref, flight: 1}}

      assert_received {:telemetry, [:aerotow, :land, :stop], %{duration: _},
                       %{ref: @ref, store: "store", flight: 1, shipped: %{bases: _}}}

      refute_received {:telemetry, [:aerotow, _, :exception], _, _}
    end
  end

  describe "20: fifty at once" do
    @tag timeout: 600_000
    test "fifty gliders created and written concurrently in one instance, landed and launched again, are all there",
         %{a: a, store: store} do
      refs = for i <- 1..50, do: "many/g#{i}"
      started = System.monotonic_time(:millisecond)

      refs
      |> Task.async_stream(
        fn ref ->
          {:ok, pid} = create(a, store, ref)
          for n <- 1..5, do: {:ok, _} = write(pid, n)
          :ok = Flight.land(pid)
        end,
        max_concurrency: 50,
        timeout: :infinity
      )
      |> Enum.each(&assert(&1 == {:ok, :ok}))

      landed = System.monotonic_time(:millisecond)

      counts =
        refs
        |> Task.async_stream(
          fn ref ->
            {:ok, pid} = launch(a, store, ref)
            n = ns(pid)
            :ok = Flight.land(pid)
            n
          end,
          max_concurrency: 50,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, n} -> n end)

      done = System.monotonic_time(:millisecond)
      assert Enum.all?(counts, &(&1 == [1, 2, 3, 4, 5]))
      assert files_under(Path.join(a.dir, "flights")) == []

      IO.puts(
        "\nfifty gliders: created, written and landed in #{landed - started} ms; " <>
          "launched, read and landed again in #{done - landed} ms"
      )
    end
  end

  describe "21: a sync that never returns" do
    test "is abandoned after sync_timeout and reported, and the flight carries on", ctx do
      %{dir: dir, clock: clock, store: store} = ctx
      a = instance(dir, "slow", clock: clock, sync_timeout: 200)
      :ok = Catalog.put_store(a.catalog, Store.public(store))
      {stall, ctl} = stalling(store)
      listen([[:aerotow, :sync, :exception]])
      {:ok, pid} = create(a, stall, @ref)
      {:ok, _} = write(pid, 1)

      StallStore.set(ctl, :replica, :block)
      assert {:error, :timeout} = Flight.sync(pid)

      assert_receive {:telemetry, [:aerotow, :sync, :exception], _,
                      %{ref: @ref, reason: :timeout}},
                     5_000

      assert %{state: :aloft, dirty: true} = Flight.info(pid)
      assert {:ok, {:ok, _}} = write(pid, 2)

      StallStore.release(ctl)
      assert {:ok, %{segments: segments}} = Flight.sync(pid)
      assert segments >= 1
      assert :ok = Flight.land(pid)
      {:ok, pid} = launch(a, store, @ref)
      assert ns(pid) == [1, 2]
    end
  end

  # Waits until `fun` is true, asking again each time the flight has
  # answered: every call to it is a turn of its loop, so no sleep is needed.
  defp wait_for(fun, tries \\ 1_000) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the condition never held")
      true -> wait_for(fun, tries - 1)
    end
  end
end
