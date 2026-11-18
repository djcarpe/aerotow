defmodule Aerotow.RecoveryTest do
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import Aerotow.FlightCase, only: [t0: 0, shipped_ns: 4, files_under: 1]

  alias Aerotow.{Instance, Lease, Store}
  alias Aerotow.Flight.{Copy, Launch}
  alias Aerotow.Store.Layout

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"
  @long %{ttl: 300_000, margin: 5_000, grace: 5_000}
  @short %{ttl: 3_000, margin: 1_000, grace: 1_000}
  @a_id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @b_id "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  defp ns(tow) do
    case Aerotow.query(tow, @ref, "MATCH (x:N) RETURN x.n ORDER BY x.n") do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [n] -> n end)
      error -> error
    end
  end

  defp write(tow, n, opts \\ []), do: Aerotow.run(tow, @ref, "CREATE (:N {n: $n})", %{n: n}, opts)

  defp plain_store(path) do
    {:ok, store} = Store.new("store", path)
    store
  end

  defp start_a(a_dir, store_path, opts \\ []) do
    {clock, _set} = clock(t0())

    tow(
      a_dir,
      [
        id: @a_id,
        stores: [{"store", store_path}],
        default_store: "store",
        clock: clock,
        timing: @long
      ] ++ opts
    )
  end

  # A glider made by A (flight 1, holding n = 1), and A stopped.
  defp made(dir) do
    a_dir = Path.join(dir, "a")
    store_path = Path.join(dir, "store")
    a = start_a(a_dir, store_path)
    {:ok, _} = Aerotow.create(a, @ref)
    {:ok, 1} = write(a, 1)
    :ok = Aerotow.land(a, @ref)
    :ok = stop_supervised!(a)
    {a_dir, store_path, plain_store(store_path)}
  end

  # A flight of A's that died: the next flight taken under A's id, and a
  # working copy restored from the store and written past it, never shipped.
  defp dead_flight(a_dir, store, extra) do
    me = %{id: @a_id, node: nil, url: nil}
    {:ok, lease} = Lease.take(store, @ref, me, fn -> t0() end, @long, takeover_own: true)
    path = Path.join([a_dir, "flights", "store", @ref <> ".gldb"])
    copy_of(store, lease.n, path, extra)
    {lease, path}
  end

  # A copy at `path` marked as flight `n`'s: what the store has below n, and
  # the nodes `extra` written past it.
  defp copy_of(store, n, path, extra) do
    {:ok, %{flight: source}} = Lease.source(store, @ref, n, &Launch.whole_base?/2)
    {url, opts} = Store.replica(store, Layout.flight_data(@ref, source))
    {:ok, _} = Copy.restore(url, opts, path)
    :ok = Copy.write_marker(path, store, @ref, n)
    {:ok, db} = Glider.open(path)
    for n <- extra, do: {:ok, 1} = Glider.run(db, "CREATE (:N {n: $n})", n: n)
    :ok = Glider.close(db)
  end

  # Every file of a copy, by its name relative to the copy, with its content.
  defp contents(path) do
    base = String.replace_suffix(path, ".gldb", "")
    dir = Path.dirname(path)

    dir
    |> files_under()
    |> Enum.filter(&String.starts_with?(&1, base))
    |> Enum.reject(&String.ends_with?(&1, [".flight.json", ".note.json", ".lock"]))
    |> Map.new(&{String.replace_prefix(&1, base, ""), File.read!(&1)})
  end

  describe "R15: carrying a copy at start" do
    test "R15: an instance that starts with a copy whose flight is still the newest takes the next flight at once and starts from the copy",
         %{tmp_dir: dir} do
      {a_dir, store_path, store} = made(dir)
      {%Lease{n: 2}, _path} = dead_flight(a_dir, store, [2, 3])

      listen([
        [:aerotow, :launch, :start],
        [:aerotow, :launch, :stop],
        [:aerotow, :sync, :stop]
      ])

      # The clock has not moved: flight 2's lease runs, and is taken over
      # because its holder is this instance's own id.
      a = start_a(a_dir, store_path)

      assert_receive {:telemetry, [:aerotow, :launch, :start], _, %{ref: @ref, intent: :carry}},
                     30_000

      assert_receive {:telemetry, [:aerotow, :launch, :stop], _, %{ref: @ref, flight: 3}}, 30_000

      assert_receive {:telemetry, [:aerotow, :sync, :stop], %{bases: 1}, %{ref: @ref, flight: 3}},
                     30_000

      # After its first shipping pass every write the copy held is in the store.
      assert shipped_ns(store, @ref, 3, dir) == [1, 2, 3]
      assert {:ok, %Lease{n: 3, from: %{carried: true}}} = Lease.current(store, @ref)
      assert ns(a) == [1, 2, 3]
      assert {:ok, []} = Aerotow.orphans(a)
    end

    test "R15: a copy whose flight was superseded goes to orphans/ untouched, and the glider is not launched from it",
         %{tmp_dir: dir} do
      {a_dir, store_path, store} = made(dir)
      {%Lease{n: 2}, path} = dead_flight(a_dir, store, [2])
      before = contents(path)

      # Somebody else took off after flight 2 ran out.
      b = %{id: @b_id, node: nil, url: nil}
      later = t0() + @long.ttl + @long.grace

      {:ok, %Lease{n: 3}} = Lease.take(store, @ref, b, fn -> later end, @long)

      a = start_a(a_dir, store_path)

      assert {:ok, [orphan]} = Aerotow.orphans(a)
      assert %{ref: @ref, store: "store", flight: 2, why: why} = orphan
      assert why =~ "superseded"
      assert contents(orphan.path) == before
      refute Copy.exists?(path)
      assert {:error, {:aloft_elsewhere, %{holder: @b_id, flight: 3}}} = ns(a)
    end

    test "R15: a copy that does not open goes to orphans/ with a note of why, and the glider launches from the store",
         %{tmp_dir: dir} do
      {a_dir, store_path, store} = made(dir)
      {%Lease{n: 2}, path} = dead_flight(a_dir, store, [2])
      Copy.remove(path)
      File.write!(path, "not a glider database")
      :ok = Copy.write_marker(path, store, @ref, 2)

      a = start_a(a_dir, store_path)

      assert {:ok, [%{ref: @ref, flight: 2, why: why, carry: false} = orphan]} =
               Aerotow.orphans(a)

      assert why =~ "does not open"
      assert File.read!(orphan.path) == "not a glider database"
      assert ns(a) == [1]
      assert {:ok, %Lease{n: 3, from: %{flight: 1}}} = Lease.current(store, @ref)
    end
  end

  describe "R15: carrying a copy a launch finds" do
    test "R15: a launch that finds a copy where its own goes, of the newest flight, carries it",
         %{tmp_dir: dir} do
      a = start_a(Path.join(dir, "a"), Path.join(dir, "store"))
      {:ok, _} = Aerotow.create(a, @ref)
      {:ok, 1} = write(a, 1)
      :ok = Aerotow.land(a, @ref)

      instance = Instance.fetch!(a)
      store = plain_store(Path.join(dir, "store"))
      copy_of(store, 2, Copy.path(instance, store, @ref), [2])
      # Its marker says flight 1, the newest, which landed.
      :ok = Copy.write_marker(Copy.path(instance, store, @ref), store, @ref, 1)

      assert ns(a) == [1, 2]
      assert {:ok, %Lease{n: 2, from: %{carried: true}}} = Lease.current(store, @ref)
    end

    test "R15: a flight that is killed is launched again by the next statement from its copy: nothing is lost",
         %{tmp_dir: dir} do
      a = start_a(Path.join(dir, "a"), Path.join(dir, "store"))
      {:ok, _} = Aerotow.create(a, @ref)
      {:ok, 1} = write(a, 1, sync: :commit)
      {:ok, 1} = write(a, 2)

      [{pid, _}] = Registry.lookup(Instance.fetch!(a).registry, @ref)
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

      # Its lease still runs, under this instance's own id: taken over at once.
      assert ns(a) == [1, 2]

      assert {:ok, %Lease{n: 2, from: %{carried: true}}} =
               Lease.current(plain_store(Path.join(dir, "store")), @ref)
    end
  end

  describe "orphans" do
    test "orphans/1 lists ref, store, flight, when, why and bytes; discard_orphan/2 deletes one, and nothing else does",
         %{tmp_dir: dir} do
      {a_dir, store_path, store} = made(dir)
      {%Lease{n: 2}, _path} = dead_flight(a_dir, store, [2])
      b = %{id: @b_id, node: nil, url: nil}
      later = t0() + @long.ttl + @long.grace
      {:ok, %Lease{n: 3}} = Lease.take(store, @ref, b, fn -> later end, @long)
      File.write!(Path.join([a_dir, "flights", "stray"]), "something else")

      a = start_a(a_dir, store_path)
      {:ok, orphans} = Aerotow.orphans(a)
      assert [_, _] = orphans
      copy = Enum.find(orphans, &(&1.ref == @ref))
      left = Enum.find(orphans, &(&1.ref == nil))

      assert %{store: "store", flight: 2, why: why, bytes: bytes, when: at, id: id} = copy
      assert why =~ "superseded"
      assert bytes > 0
      assert at == t0()
      assert id == "store/#{@ref}.2.gldb"
      assert %{why: left_why, bytes: 14} = left
      assert left_why =~ "no working copy"

      # A launch, and a start on the same dir, leave them where they are.
      _ = ns(a)
      :ok = stop_supervised!(a)
      a = start_a(a_dir, store_path)
      assert {:ok, ^orphans} = Aerotow.orphans(a)

      assert Aerotow.discard_orphan(a, "../instance.json") == {:error, :not_found}
      assert Aerotow.discard_orphan(a, "store/nothing.1.gldb") == {:error, :not_found}
      assert :ok = Aerotow.discard_orphan(a, id)
      assert {:ok, [^left]} = Aerotow.orphans(a)
      refute Copy.exists?(copy.path)
      refute File.exists?(Path.join(a_dir, "orphans/store"))
      assert :ok = Aerotow.discard_orphan(a, left.id)
      assert {:ok, []} = Aerotow.orphans(a)
      assert File.exists?(Path.join(a_dir, "instance.json"))
    end
  end

  describe "telemetry" do
    test "[:aerotow, :lease, :renewed | :lost] and [:aerotow, :flight, :orphaned] as a flight renews, runs out and is set aside",
         %{tmp_dir: dir} do
      {clock, set} = clock(t0())
      store_path = Path.join(dir, "store")
      on_exit(fn -> writable(store_path, true) end)

      a =
        tow(Path.join(dir, "a"),
          stores: [{"store", store_path}],
          default_store: "store",
          clock: clock,
          timing: @short
        )

      listen([
        [:aerotow, :lease, :renewed],
        [:aerotow, :lease, :lost],
        [:aerotow, :flight, :orphaned]
      ])

      {:ok, _} = Aerotow.create(a, @ref)

      renew_at = t0() + div(@short.ttl, 3) + 1
      set.(renew_at)
      expires_at = renew_at + @short.ttl

      assert_receive {:telemetry, [:aerotow, :lease, :renewed], %{expires_at: ^expires_at},
                      %{ref: @ref, store: "store", flight: 1}},
                     10_000

      # A write the store cannot take: a flight ticks every ttl / 10 and
      # ships what is dirty, so the store is made unwritable first.
      writable(store_path, false)
      {:ok, 1} = write(a, 1)
      set.(expires_at - @short.margin)

      assert_receive {:telemetry, [:aerotow, :lease, :lost], _,
                      %{ref: @ref, store: "store", flight: 1, reason: :deadline}},
                     10_000

      assert_receive {:telemetry, [:aerotow, :flight, :orphaned], _,
                      %{ref: @ref, store: "store", flight: 1, path: path}},
                     10_000

      assert {:ok, [%{path: ^path}]} = Aerotow.orphans(a)
    end

    test "[:aerotow, :evict] when a flight lands to make room", %{tmp_dir: dir} do
      a =
        tow(Path.join(dir, "a"),
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store",
          max_aloft: 1
        )

      listen([[:aerotow, :evict]])
      {:ok, _} = Aerotow.create(a, "g/one")
      {:ok, _} = Aerotow.create(a, "g/two")

      assert_received {:telemetry, [:aerotow, :evict], %{bytes: bytes},
                       %{ref: "g/one", store: "store", flight: 1, why: :max_aloft}}

      assert bytes > 0
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
