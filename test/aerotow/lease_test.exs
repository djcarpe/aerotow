defmodule Aerotow.LeaseTest do
  # Not async: the first store in a VM loads code and makes atoms, and
  # Aerotow.CardTest counts the VM's atoms while it runs.
  use ExUnit.Case, async: false

  alias Aerotow.{Lease, Store}
  alias Aerotow.Store.Layout

  doctest Aerotow.Lease

  @moduletag :tmp_dir

  @timing %{ttl: 30_000, margin: 5_000, grace: 5_000}
  @t0 1_763_400_000_000

  # ------------------------------------------------------------------ helpers

  defp store(dir) do
    {:ok, store} = Store.new("dir", Path.join(dir, "store"))
    store
  end

  defp me(i, opts \\ []) do
    id = i |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
    %{id: id, node: Keyword.get(opts, :node), url: Keyword.get(opts, :url)}
  end

  # A clock the test moves: {clock, set}.
  defp clock(t \\ @t0) do
    agent = start_supervised!({Agent, fn -> t end}, id: make_ref())
    {fn -> Agent.get(agent, & &1) end, fn t -> Agent.update(agent, fn _ -> t end) end}
  end

  defp fixed(t), do: fn -> t end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(10, "0")

  # A whole_base? that says yes for the flights named, and tells the test
  # process which flights it was asked about.
  defp bases(flights) do
    test = self()
    names = MapSet.new(flights, &pad/1)

    fn url, opts when is_binary(url) and is_list(opts) ->
      name = Path.basename(url)
      send(test, {:asked, String.to_integer(name)})
      {:ok, name in names}
    end
  end

  defp asked do
    receive do
      {:asked, n} -> [n | asked()]
    after
      0 -> []
    end
  end

  defp record(ref, n, opts \\ []) do
    struct(
      %Lease{
        ref: ref,
        n: n,
        holder: Keyword.get(opts, :holder, me(1).id),
        started_at: @t0,
        expires_at: @t0 + @timing.ttl
      },
      Keyword.drop(opts, [:holder])
    )
  end

  defp put_record(store, %Lease{} = lease),
    do: :ok = Store.put(store, Layout.flight_record(lease.ref, lease.n), Lease.encode(lease))

  defp put_raw(store, ref, n, body),
    do: :ok = Store.put(store, Layout.flight_record(ref, n), body)

  defp put_data(store, ref, n, name \\ "base/1/db"),
    do: :ok = Store.put(store, Layout.flight_data(ref, n) <> "/" <> name, "x")

  defp snapshot(store) do
    {:ok, %{objects: objects}} = Store.list(store, "gliders/")

    Map.new(objects, fn %{key: key} ->
      {:ok, body} = Store.get(store, key)
      {key, body}
    end)
  end

  # A hangared glider: flight 1, created and landed.
  defp hangared(store, ref) do
    {:ok, lease} = Lease.take(store, ref, me(1), fixed(@t0), @timing, create: true)
    {:ok, landed} = Lease.land(store, lease, nil, fixed(@t0), @timing)
    landed
  end

  defp race(store, ref, count, opts) do
    1..count
    |> Enum.map(fn i ->
      Task.async(fn -> Lease.take(store, ref, me(i), fixed(@t0), @timing, opts) end)
    end)
    |> Task.await_many(30_000)
  end

  # Whether the dir store refuses this process a directory it has taken
  # every permission from: as root it does not, and those tests say nothing.
  defp permissions_hold?(dir) do
    probe = Path.join(dir, "permissions")
    File.mkdir_p!(probe)
    File.chmod!(probe, 0o000)
    held = match?({:error, :eacces}, File.ls(probe))
    File.chmod!(probe, 0o755)
    held
  end

  # ------------------------------------------------------------------ the record

  describe "encode/1 and decode/1" do
    test "a record reads back as it was written, every field" do
      lease =
        record("engineering/code", 7,
          node: "app@10.0.0.7",
          url: "https://west.example.com/aerotow",
          from: %{flight: 6, generation: "96348bfb", position: 1_040_112},
          landed: true,
          landed_at: @t0 + 10,
          shipped: %{generation: "96348bfb", position: 1_048_665, bases: 1}
        )

      assert {:ok, ^lease} = lease |> Lease.encode() |> Lease.decode()

      carried = record("a", 2, from: %{carried: true})
      assert {:ok, ^carried} = carried |> Lease.encode() |> Lease.decode()
    end

    test "the same lease is the same bytes, and they are the design's JSON" do
      lease = record("a", 3)
      assert Lease.encode(lease) == Lease.encode(lease)

      assert {:ok, map} = JSON.decode(Lease.encode(lease))

      assert map == %{
               "format" => 1,
               "ref" => "a",
               "n" => 3,
               "holder" => me(1).id,
               "node" => nil,
               "url" => nil,
               "started_at" => @t0,
               "expires_at" => @t0 + 30_000,
               "from" => nil,
               "landed" => false,
               "landed_at" => nil,
               "shipped" => nil
             }
    end

    test "fields it does not know are ignored" do
      {:ok, map} = JSON.decode(Lease.encode(record("a", 1)))
      body = JSON.encode!(Map.put(map, "later", %{"x" => 1}))
      assert {:ok, %Lease{ref: "a", n: 1}} = Lease.decode(body)
    end
  end

  # ------------------------------------------------------------------ R6

  describe "R6: a record read from a store is input" do
    setup %{tmp_dir: dir}, do: %{store: store(dir)}

    test "R6: what is not a well-formed record is an error from read/3", %{store: store} do
      {:ok, good} = JSON.decode(Lease.encode(record("a", 1)))

      bad = [
        "not json",
        "[1, 2]",
        "",
        JSON.encode!(%{good | "format" => 2}),
        JSON.encode!(Map.delete(good, "format")),
        JSON.encode!(%{good | "ref" => "b"}),
        JSON.encode!(%{good | "ref" => "../a"}),
        JSON.encode!(%{good | "n" => 2}),
        JSON.encode!(%{good | "n" => "1"}),
        JSON.encode!(%{good | "started_at" => -1}),
        JSON.encode!(%{good | "expires_at" => 1.5}),
        JSON.encode!(%{good | "expires_at" => "soon"}),
        JSON.encode!(%{good | "holder" => "abc"}),
        JSON.encode!(%{good | "holder" => String.duplicate("A", 32)}),
        JSON.encode!(%{good | "holder" => String.duplicate("g", 32)}),
        JSON.encode!(%{good | "landed" => true}),
        JSON.encode!(%{good | "landed_at" => @t0}),
        JSON.encode!(%{good | "node" => 7}),
        JSON.encode!(%{good | "url" => "ftp://x"}),
        JSON.encode!(%{good | "url" => "https://user:secret@example.com/"}),
        JSON.encode!(%{good | "from" => %{"flight" => 1}}),
        JSON.encode!(%{good | "from" => "flight 0"}),
        JSON.encode!(%{
          good
          | "shipped" => %{"generation" => "zz", "position" => 1, "bases" => 1}
        }),
        String.duplicate(" ", 70_000)
      ]

      for body <- bad do
        put_raw(store, "a", 1, body)
        assert {:error, reason} = Lease.read(store, "a", 1), "read #{inspect(body)} as a record"
        assert is_binary(reason)
      end

      put_raw(store, "a", 1, JSON.encode!(good))
      assert {:ok, %Lease{n: 1}} = Lease.read(store, "a", 1)
      assert {:error, :not_found} = Lease.read(store, "a", 2)
    end

    test "R6: nothing in a record becomes an atom", %{store: store} do
      {:ok, good} = JSON.decode(Lease.encode(record("a", 1)))
      name = "aerotow_lease_never_an_atom_#{System.unique_integer([:positive])}"
      body = JSON.encode!(Map.merge(good, %{name => name, "node" => name <> "@host"}))
      put_raw(store, "a", 1, body)

      assert {:ok, %Lease{node: node}} = Lease.read(store, "a", 1)
      assert node == name <> "@host"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(name <> "@host") end
    end

    test "R6: current/2 with an unreadable highest record is an error, not a free glider", %{
      store: store
    } do
      put_record(store, record("a", 1, landed: true, landed_at: @t0))
      put_raw(store, "a", 2, "garbage")

      assert {:error, reason} = Lease.current(store, "a")
      assert is_binary(reason)

      assert {:error, _} = Lease.take(store, "a", me(2), fixed(@t0 + 10 ** 9), @timing)
      assert {:error, :exists} = Lease.take(store, "a", me(2), fixed(@t0), @timing, create: true)
    end

    test "R6: flights/2 lists numbers from keys alone and ignores what is not a record", %{
      store: store
    } do
      put_record(store, record("a", 1))
      put_raw(store, "a", 3, "not even json")
      put_data(store, "a", 1)
      put_data(store, "a", 4, "base/1/db.partial")
      prefix = Layout.flights_prefix("a")

      for stray <- ["notes.txt", "1.json", "+000000002.json", "00000000005.json", "0000000006.js"],
          do: :ok = Store.put(store, prefix <> stray, "x")

      :ok = Store.put(store, prefix <> "elsewhere/0000000009.json", "x")
      put_record(store, record("a/b", 8))

      assert {:ok, [1, 3]} = Lease.flights(store, "a")
      assert {:ok, [8]} = Lease.flights(store, "a/b")
      assert {:ok, []} = Lease.flights(store, "c")
    end

    test "R6: a record copied to another flight's key is not believed", %{store: store} do
      :ok = Store.put(store, Layout.flight_record("a", 2), Lease.encode(record("a", 1)))
      :ok = Store.put(store, Layout.flight_record("b", 1), Lease.encode(record("a", 1)))

      assert {:error, reason} = Lease.read(store, "a", 2)
      assert reason =~ "flight 1"
      assert {:error, _} = Lease.read(store, "b", 1)
    end

    test "R1: a ref is parsed before it becomes a key", %{store: store} do
      for ref <- ["../a", "A", "_flights", "a//b", 7, nil] do
        assert {:error, _} = Lease.flights(store, ref)
        assert {:error, _} = Lease.read(store, ref, 1)
        assert {:error, _} = Lease.current(store, ref)
        assert {:error, _} = Lease.take(store, ref, me(1), fixed(@t0), @timing, create: true)
        assert {:error, _} = Lease.source(store, ref, 2, bases([]))
        assert {:error, _} = Lease.retire(store, ref, fixed(@t0), 1, bases([]))
      end
    end
  end

  # ------------------------------------------------------------------ R7

  describe "R7: exactly one taker wins" do
    setup %{tmp_dir: dir}, do: %{store: store(dir)}

    # Hundreds of rounds of fsynced exclusive puts: minutes on a loaded machine.
    @tag timeout: 600_000
    test "R7: of sixteen takers of a hangared glider one wins, round after round, and flights go 1, 2, 3, … with no gap",
         %{store: store} do
      hangared(store, "race")
      rounds = 200

      for round <- 1..rounds do
        results = race(store, "race", 16, [])
        winners = for {:ok, lease} <- results, do: lease
        assert [winner] = winners, "round #{round}: #{inspect(results)}"
        assert winner.n == round + 1

        for result <- results, not match?({:ok, _}, result) do
          assert {:error, {:aloft, %Lease{n: n, holder: holder}}} = result
          assert {n, holder} == {winner.n, winner.holder}
        end

        assert {:ok, _} = Lease.land(store, winner, nil, fixed(@t0), @timing)
      end

      assert {:ok, flights} = Lease.flights(store, "race")
      assert flights == Enum.to_list(1..(rounds + 1))
    end

    # Hundreds of rounds of fsynced exclusive puts: minutes on a loaded machine.
    @tag timeout: 600_000
    test "R7: of sixteen creators of a new glider one creates flight 1 and the rest find it exists",
         %{store: store} do
      for round <- 1..100 do
        ref = "new/g#{round}"
        results = race(store, ref, 16, create: true)
        assert [%Lease{n: 1}] = for({:ok, lease} <- results, do: lease)
        assert Enum.count(results, &(&1 == {:error, :exists})) == 15
        assert {:ok, [1]} = Lease.flights(store, ref)
      end
    end

    test "R7: without create: a glider with no flight is not found; with it, a glider with one exists",
         %{store: store} do
      assert {:error, :not_found} = Lease.take(store, "a", me(1), fixed(@t0), @timing)

      assert {:ok, %Lease{n: 1}} =
               Lease.take(store, "a", me(1), fixed(@t0), @timing, create: true)

      assert {:error, :exists} = Lease.take(store, "a", me(2), fixed(@t0), @timing, create: true)
      assert {:ok, [1]} = Lease.flights(store, "a")
    end

    test "R7: a new lease records its holder, how to reach it, where it started, and runs for ttl",
         %{store: store} do
      hangared(store, "a")
      me = me(2, node: "app@10.0.0.7", url: "https://west.example.com/aerotow")
      from = %{flight: 1, generation: "abc", position: 10}

      assert {:ok, lease} = Lease.take(store, "a", me, fixed(@t0 + 5), @timing, from: from)

      assert %Lease{
               n: 2,
               holder: holder,
               node: "app@10.0.0.7",
               url: "https://west.example.com/aerotow",
               started_at: started,
               expires_at: expires,
               from: ^from,
               landed: false,
               shipped: nil
             } = lease

      assert {holder, started, expires} == {me.id, @t0 + 5, @t0 + 5 + 30_000}
      assert {:ok, ^lease} = Lease.read(store, "a", 2)

      {:ok, landed} = Lease.land(store, lease, nil, fixed(@t0 + 5), @timing)
      assert {:ok, carried} = Lease.take(store, "a", me, fixed(@t0 + 6), @timing, carried: true)
      assert carried.from == %{carried: true}
      assert landed.landed

      assert {:error, _} =
               Lease.take(store, "a", me, fixed(@t0), @timing, carried: true, from: from)

      assert {:error, _} = Lease.take(store, "a", me, fixed(@t0), @timing, from: %{flight: 9})
      assert {:error, _} = Lease.take(store, "a", me, fixed(@t0), @timing, nonsense: true)
      assert {:error, _} = Lease.take(store, "a", %{id: "nope"}, fixed(@t0), @timing)
      assert {:error, _} = Lease.take(store, "a", me, :not_a_clock, @timing)
      assert {:error, _} = Lease.take(store, "a", me, fixed(@t0), %{ttl: 1})
    end
  end

  # ------------------------------------------------------------------ R8, R9

  describe "R8, R9: active means not takeable" do
    setup %{tmp_dir: dir}, do: %{store: store(dir)}

    test "R8: while the current flight is active and not ours, take/6 is aloft and writes nothing",
         %{store: store} do
      {:ok, held} = Lease.take(store, "a", me(1), fixed(@t0), @timing, create: true)
      before = snapshot(store)
      last_active = held.expires_at + @timing.grace - 1

      for now <- [@t0, @t0 + 29_999, held.expires_at, last_active] do
        assert {:error, {:aloft, ^held}} = Lease.take(store, "a", me(2), fixed(now), @timing)
        assert Lease.active?(held, now, @timing)
      end

      assert snapshot(store) == before
    end

    test "R9: at the first instant it is no longer active, take/6 succeeds with n + 1", %{
      store: store
    } do
      {:ok, held} = Lease.take(store, "a", me(1), fixed(@t0), @timing, create: true)
      free = held.expires_at + @timing.grace

      refute Lease.active?(held, free, @timing)
      assert {:ok, %Lease{n: 2} = next} = Lease.take(store, "a", me(2), fixed(free), @timing)
      assert {:ok, ^next} = Lease.current(store, "a")
    end

    test "R9: after land/5 the glider can be taken at once", %{store: store} do
      {:ok, held} = Lease.take(store, "a", me(1), fixed(@t0), @timing, create: true)
      {:ok, landed} = Lease.land(store, held, nil, fixed(@t0 + 1), @timing)

      refute Lease.active?(landed, @t0 + 1, @timing)
      assert {:ok, %Lease{n: 2}} = Lease.take(store, "a", me(2), fixed(@t0 + 1), @timing)
    end

    test "R8: the current flight is the highest number, and nil when there is none", %{
      store: store
    } do
      assert {:ok, nil} = Lease.current(store, "a")
      put_record(store, record("a", 1, landed: true, landed_at: @t0))
      put_record(store, record("a", 2))
      assert {:ok, %Lease{n: 2}} = Lease.current(store, "a")
    end

    test "R8: a flight's directory above every record means the glider cannot be called free", %{
      store: store
    } do
      put_record(store, record("a", 1, landed: true, landed_at: @t0))
      put_data(store, "a", 2)

      assert {:error, _} = Lease.current(store, "a")
      assert {:error, _} = Lease.take(store, "a", me(2), fixed(@t0), @timing)
    end
  end

  # ------------------------------------------------------------------ R10

  describe "R10: renewing and holding" do
    setup %{tmp_dir: dir} do
      store = store(dir)
      {clock, set} = clock()
      {:ok, lease} = Lease.take(store, "a", me(1), clock, @timing, create: true)
      %{store: store, clock: clock, set: set, lease: lease}
    end

    test "R10: renew/4 moves expires_at to now + ttl, and the store's record says so", %{
      store: store,
      clock: clock,
      set: set,
      lease: lease
    } do
      set.(@t0 + 10_000)
      assert {:ok, renewed} = Lease.renew(store, lease, clock, @timing)
      assert renewed.expires_at == @t0 + 10_000 + 30_000
      assert {:ok, ^renewed} = Lease.read(store, "a", 1)

      set.(@t0 + 20_000)
      assert {:ok, again} = Lease.renew(store, renewed, clock, @timing)
      assert again.expires_at == @t0 + 50_000
      assert {:ok, ^again} = Lease.current(store, "a")
    end

    test "R10: a lease no longer valid when renewed is lost, and nothing is written", %{
      store: store,
      clock: clock,
      set: set,
      lease: lease
    } do
      before = snapshot(store)
      set.(Lease.deadline(lease, @timing))
      refute Lease.valid?(lease, Lease.deadline(lease, @timing), @timing)

      assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)
      assert {:error, :lost} = Lease.update(store, lease, [shipped: nil], clock, @timing)
      assert {:error, :lost} = Lease.land(store, lease, nil, clock, @timing)
      assert snapshot(store) == before
    end

    test "R10: a record that is no longer this flight's as its holder wrote it means lost, and nothing is written",
         %{store: store, clock: clock, lease: lease} do
      changed = [
        {"another holder", &put_record(&1, %{lease | holder: me(2).id})},
        {"another start", &put_record(&1, %{lease | started_at: lease.started_at + 1})},
        {"landed", &put_record(&1, %{lease | landed: true, landed_at: @t0})},
        {"missing", &(:ok = Store.delete(&1, Layout.flight_record("a", 1)))},
        {"unreadable", &put_raw(&1, "a", 1, "{")},
        {"someone else's record", &put_raw(&1, "a", 1, Lease.encode(record("b", 1)))}
      ]

      for {what, change} <- changed do
        put_record(store, lease)
        change.(store)
        before = snapshot(store)

        assert {:error, :lost} = Lease.renew(store, lease, clock, @timing), what

        assert {:error, :lost} =
                 Lease.update(store, lease, [from: %{carried: true}], clock, @timing),
               what

        assert snapshot(store) == before, what
      end
    end

    test "R10: a higher flight means lost, and nothing is written", %{
      store: store,
      clock: clock,
      lease: lease
    } do
      for higher <- [
            &put_record(&1, record("a", 2, holder: me(2).id)),
            &put_data(&1, "a", 3)
          ] do
        higher.(store)
        before = snapshot(store)
        assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)
        assert {:error, :lost} = Lease.update(store, lease, [shipped: nil], clock, @timing)
        assert {:error, :lost} = Lease.land(store, lease, nil, clock, @timing)
        assert snapshot(store) == before
      end
    end

    test "R10: a renewal whose write completes after the deadline is lost", %{
      store: store,
      lease: lease
    } do
      ticks = :counters.new(1, [])
      deadline = Lease.deadline(lease, @timing)

      clock = fn ->
        :counters.add(ticks, 1, 1)
        if :counters.get(ticks, 1) == 1, do: deadline - 1, else: deadline
      end

      assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)
    end

    test "R10: once lost, always lost", %{store: store, clock: clock, set: set, lease: lease} do
      put_record(store, record("a", 2, holder: me(2).id, landed: true, landed_at: @t0))
      assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)

      :ok = Store.delete(store, Layout.flight_record("a", 2))

      # The record that went was the one that lost it; even so nothing comes
      # back once time has run out.
      set.(Lease.deadline(lease, @timing))

      for _ <- 1..3 do
        assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)
        assert {:error, :lost} = Lease.update(store, lease, [shipped: nil], clock, @timing)
        assert {:error, :lost} = Lease.land(store, lease, nil, clock, @timing)
      end

      set.(@t0 + 10 ** 9)
      assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)
    end

    test "R10: a lost landing stays lost when the glider is taken by somebody else", %{
      store: store,
      clock: clock,
      set: set,
      lease: lease
    } do
      free = lease.expires_at + @timing.grace
      {:ok, _} = Lease.take(store, "a", me(2), fixed(free), @timing)

      for now <- [@t0 + 1, Lease.deadline(lease, @timing) - 1, free] do
        set.(now)
        assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)
        assert {:error, :lost} = Lease.update(store, lease, [shipped: nil], clock, @timing)
        assert {:error, :lost} = Lease.land(store, lease, nil, clock, @timing)
      end
    end

    test "update/5 records from: and shipped: in the store", %{
      store: store,
      clock: clock,
      lease: lease
    } do
      shipped = %{generation: "96348bfb", position: 1_048_665, bases: 1}
      assert {:ok, updated} = Lease.update(store, lease, [shipped: shipped], clock, @timing)
      assert updated.shipped == shipped
      assert {:ok, ^updated} = Lease.read(store, "a", 1)

      assert {:ok, carried} =
               Lease.update(store, updated, [from: %{carried: true}], clock, @timing)

      assert {:ok, %Lease{from: %{carried: true}, shipped: ^shipped}} = Lease.read(store, "a", 1)
      assert carried.from == %{carried: true}

      assert {:error, _} = Lease.update(store, carried, [holder: "x"], clock, @timing)
      assert {:error, _} = Lease.update(store, carried, [shipped: %{bases: 1}], clock, @timing)
      assert {:error, _} = Lease.update(store, carried, [from: %{flight: 1}], clock, @timing)
    end

    test "land/5 records the landing and what was shipped, and a repeated landing answers the same",
         %{store: store, clock: clock, set: set, lease: lease} do
      set.(@t0 + 7)
      shipped = %{generation: "ab", position: 9, bases: 1}
      assert {:ok, landed} = Lease.land(store, lease, shipped, clock, @timing)
      assert %Lease{landed: true, landed_at: at, shipped: ^shipped} = landed
      assert at == @t0 + 7
      assert {:ok, ^landed} = Lease.read(store, "a", 1)

      set.(@t0 + 8)
      assert {:ok, ^landed} = Lease.land(store, lease, shipped, clock, @timing)
      assert {:error, :lost} = Lease.renew(store, lease, clock, @timing)
    end
  end

  # ------------------------------------------------------------------ two clocks

  describe "two clocks" do
    # For a record and a skew between holder and taker, a real instant at
    # which the holder's valid?/3 is true and the taker finds the flight not
    # active (so take/6 would succeed), or nil. Only instants next to the two
    # boundaries need trying: both predicates are steps in time.
    defp both_proceed(lease, holder_skew, taker_skew, timing) do
      held_until = lease.expires_at - timing.margin - holder_skew
      free_from = lease.expires_at + timing.grace - taker_skew

      Enum.find(
        for(at <- [held_until, free_from], d <- -2..2, do: at + d),
        fn real ->
          Lease.valid?(lease, real + holder_skew, timing) and
            not Lease.active?(lease, real + taker_skew, timing)
        end
      )
    end

    defp random_timing do
      ttl = Enum.random(3_000..120_000)
      margin = Enum.random(1..div(ttl * 2 - 1, 3))
      %{ttl: ttl, margin: margin, grace: Enum.random(0..20_000)}
    end

    test "R10, R11: clocks that differ by less than margin + grace never both proceed" do
      for _ <- 1..5_000 do
        timing = random_timing()
        expires_at = @t0 + Enum.random(0..(10 ** 9))
        lease = record("a", Enum.random(1..1_000), expires_at: expires_at)
        bound = timing.margin + timing.grace
        holder_skew = Enum.random((-10 ** 7)..(10 ** 7))
        taker_skew = holder_skew + Enum.random(-(bound - 1)..(bound - 1))

        assert both_proceed(lease, holder_skew, taker_skew, timing) == nil,
               inspect({lease.expires_at, timing, holder_skew, taker_skew})
      end
    end

    test "R10, R11: as soon as the skew exceeds margin + grace, both can proceed", %{
      tmp_dir: dir
    } do
      for _ <- 1..1_000 do
        timing = random_timing()
        lease = record("a", 1, expires_at: @t0 + Enum.random(0..(10 ** 9)))
        bound = timing.margin + timing.grace
        holder_skew = Enum.random((-10 ** 7)..(10 ** 7))

        assert both_proceed(lease, holder_skew, holder_skew + bound, timing) == nil
        assert both_proceed(lease, holder_skew, holder_skew + bound + 1, timing) != nil
      end

      # And through a store: a holder whose clock is behind by more than the
      # bound still renews while a taker takes the glider.
      store = store(dir)
      {:ok, held} = Lease.take(store, "a", me(1), fixed(@t0), @timing, create: true)
      skew = @timing.margin + @timing.grace + 1
      real = held.expires_at + @timing.grace
      assert Lease.valid?(held, real - skew, @timing)
      assert {:ok, %Lease{n: 2}} = Lease.take(store, "a", me(2), fixed(real), @timing)
    end
  end

  # ------------------------------------------------------------------ own flight

  describe "taking over one's own dead flight" do
    setup %{tmp_dir: dir}, do: %{store: store(dir)}

    test "an active flight of our own is taken over at once with takeover_own: true, and only then",
         %{store: store} do
      {:ok, dead} = Lease.take(store, "a", me(1), fixed(@t0), @timing, create: true)

      assert {:error, {:aloft, ^dead}} = Lease.take(store, "a", me(1), fixed(@t0 + 1), @timing)

      assert {:error, {:aloft, ^dead}} =
               Lease.take(store, "a", me(2), fixed(@t0 + 1), @timing, takeover_own: true)

      assert {:ok, %Lease{n: 2, holder: holder}} =
               Lease.take(store, "a", me(1), fixed(@t0 + 1), @timing, takeover_own: true)

      assert holder == me(1).id
      assert {:error, :lost} = Lease.renew(store, dead, fixed(@t0 + 2), @timing)
    end
  end

  # ------------------------------------------------------------------ R12, R13

  describe "R12, R13: where to restore from" do
    setup %{tmp_dir: dir} do
      store = store(dir)
      landed = [landed: true, landed_at: @t0 + 100]

      # 1 shipped a base and landed; 2 only read and landed; 3 died while
      # uploading its first base; 4 is ours.
      put_record(
        store,
        record("a", 1, [shipped: %{generation: "aa", position: 5, bases: 1}] ++ landed)
      )

      put_data(store, "a", 1)

      put_record(
        store,
        record("a", 2, [from: %{flight: 1, generation: "aa", position: 5}] ++ landed)
      )

      put_record(store, record("a", 3, from: %{flight: 2, generation: nil, position: nil}))
      put_data(store, "a", 3, "base/7/db.partial")
      put_data(store, "a", 3, "segments/0-1.seg")
      put_record(store, record("a", 4, holder: me(9).id, from: nil))

      %{store: store}
    end

    test "R12: the source is the newest earlier flight with a whole base, found by asking", %{
      store: store
    } do
      assert {:ok, %{flight: 1}} = Lease.source(store, "a", 4, bases([1]))
      calls = asked()
      assert 3 in calls and 1 in calls
      assert length(calls) <= 4
    end

    test "R12: a flight without a whole base is skipped through its from", %{store: store} do
      # With 3 started from 1, whole_base? is asked about 3 and then 1,
      # never about 2.
      put_record(store, record("a", 3, from: %{flight: 1, generation: "aa", position: 5}))
      assert {:ok, %{flight: 1}} = Lease.source(store, "a", 4, bases([1, 2]))
      assert Enum.sort(asked()) == [1, 3]

      # 3 started from 2, which only read and started from 1.
      put_record(store, record("a", 3, from: %{flight: 2, generation: nil, position: nil}))
      assert {:ok, %{flight: 1}} = Lease.source(store, "a", 4, bases([1]))
      assert Enum.sort(asked()) == [1, 2, 3]
    end

    test "R12: a flight that shipped is chosen even if its record says it did not", %{
      store: store
    } do
      assert {:ok, %{flight: 3}} = Lease.source(store, "a", 4, bases([1, 3]))
      put_record(store, record("a", 3, from: nil))
      assert {:ok, %{flight: 2}} = Lease.source(store, "a", 3, bases([2]))
    end

    test "R12: a record that claims a base is not believed when whole_base? says no", %{
      store: store
    } do
      assert {:ok, nil} = Lease.source(store, "a", 4, bases([]))
      assert {:ok, nil} = Lease.source(store, "a", 2, bases([]))
    end

    test "R12: a missing or unreadable record gives way to the next lower flight", %{
      store: store
    } do
      :ok = Store.delete(store, Layout.flight_record("a", 3))
      assert {:ok, %{flight: 2}} = Lease.source(store, "a", 4, bases([2]))
      _ = asked()

      put_raw(store, "a", 3, "{ not json")
      assert {:ok, %{flight: 2}} = Lease.source(store, "a", 4, bases([2]))
      assert Enum.sort(asked()) == [2, 3]

      put_raw(store, "a", 2, "nope")
      assert {:ok, %{flight: 1}} = Lease.source(store, "a", 4, bases([1]))
    end

    test "R12: it never asks more than once per flight that exists", %{store: store} do
      for n <- 5..40, do: put_record(store, record("a", n, from: %{flight: n - 1}))
      assert {:ok, %{flight: 1}} = Lease.source(store, "a", 41, bases([1]))
      calls = asked()
      assert calls == Enum.uniq(calls)
      assert length(calls) <= 40

      assert {:ok, nil} = Lease.source(store, "a", 41, bases([]))
      calls = asked()
      assert calls == Enum.uniq(calls)
      assert length(calls) <= 40
    end

    test "R13: source/4 only looks below the number it is given", %{store: store} do
      assert {:ok, nil} = Lease.source(store, "a", 1, bases([1, 2, 3, 4]))
      assert asked() == []
      assert {:ok, %{flight: 1}} = Lease.source(store, "a", 2, bases([1, 2, 3, 4]))
      assert asked() == [1]
      assert {:ok, %{flight: 3}} = Lease.source(store, "a", 4, bases([1, 2, 3, 4]))
      assert 4 not in asked()
    end

    test "R13: take/6 hands out no flight while a lower one is active", %{store: store} do
      # Flight 4 is somebody else's and active: nobody gets flight 5.
      assert {:error, {:aloft, %Lease{n: 4}}} =
               Lease.take(store, "a", me(1), fixed(@t0 + 1), @timing)

      assert {:ok, [1, 2, 3, 4]} = Lease.flights(store, "a")

      free = @t0 + @timing.ttl + @timing.grace
      assert {:ok, %Lease{n: 5}} = Lease.take(store, "a", me(1), fixed(free), @timing)
    end

    test "R12: what whole_base? answers wrongly is an error, not a source", %{store: store} do
      assert {:error, _} = Lease.source(store, "a", 4, fn _, _ -> {:error, :down} end)
      assert {:error, _} = Lease.source(store, "a", 4, fn _, _ -> :maybe end)
      assert {:error, _} = Lease.source(store, "a", 4, fn _, _ -> raise "boom" end)
      assert {:error, _} = Lease.source(store, "a", 4, :not_a_function)
      assert {:error, _} = Lease.source(store, "a", 0, bases([1]))
    end
  end

  # ------------------------------------------------------------------ no CAS

  describe "no CAS, no lease" do
    setup %{tmp_dir: dir}, do: %{store: store(dir)}

    test "a store whose cas is false cannot take, unless it is single_writer", %{store: store} do
      no_cas = %{store | cas: false}

      assert {:error, :no_cas} =
               Lease.take(no_cas, "a", me(1), fixed(@t0), @timing, create: true)

      assert {:ok, []} = Lease.flights(store, "a")

      single = %{no_cas | single_writer: true}

      assert {:ok, %Lease{n: 1} = lease} =
               Lease.take(single, "a", me(1), fixed(@t0), @timing, create: true)

      assert {:ok, _} = Lease.land(single, lease, nil, fixed(@t0), @timing)
      assert {:ok, %Lease{n: 2}} = Lease.take(single, "a", me(1), fixed(@t0), @timing)

      assert {:error, :no_cas} = Lease.take(%{store | cas: nil}, "a", me(1), fixed(@t0), @timing)
    end

    test "a store that holds no objects is refused by every function", %{tmp_dir: dir} do
      {:ok, file} = Store.new("disk", Path.join(dir, "files"), kind: :file)
      lease = record("a", 1)

      assert {:error, :not_objects} = Lease.flights(file, "a")
      assert {:error, :not_objects} = Lease.read(file, "a", 1)
      assert {:error, :not_objects} = Lease.current(file, "a")
      assert {:error, :not_objects} = Lease.take(file, "a", me(1), fixed(@t0), @timing)
      assert {:error, :not_objects} = Lease.renew(file, lease, fixed(@t0), @timing)
      assert {:error, :not_objects} = Lease.update(file, lease, [], fixed(@t0), @timing)
      assert {:error, :not_objects} = Lease.land(file, lease, nil, fixed(@t0), @timing)
      assert {:error, :not_objects} = Lease.source(file, "a", 2, bases([]))
      assert {:error, :not_objects} = Lease.retire(file, "a", fixed(@t0), 1, bases([]))
    end
  end

  # ------------------------------------------------------------------ retention

  describe "retention" do
    setup %{tmp_dir: dir} do
      store = store(dir)
      day = 86_400_000

      # 1, 2 landed long ago; 3 never landed and ran out long ago; 4 has the
      # newest whole base and landed long ago; 5 landed recently; 6 is aloft.
      for n <- [1, 2] do
        put_record(store, record("a", n, landed: true, landed_at: @t0))
        put_data(store, "a", n)
        put_data(store, "a", n, "segments/0-1.seg")
      end

      put_record(store, record("a", 3, expires_at: @t0 + 30_000))
      put_data(store, "a", 3, "base/1/db.partial")
      put_record(store, record("a", 4, landed: true, landed_at: @t0))
      put_data(store, "a", 4)
      put_record(store, record("a", 5, landed: true, landed_at: @t0 + 3 * day))
      put_record(store, record("a", 6, started_at: @t0 + 3 * day, expires_at: @t0 + 3 * day))

      # Another glider whose name starts the same way.
      for n <- 1..2 do
        put_record(store, record("a/b", n, landed: true, landed_at: @t0))
        put_data(store, "a/b", n)
      end

      %{store: store, day: day, now: fixed(@t0 + 3 * day)}
    end

    defp keys(store, prefix) do
      {:ok, %{objects: objects}} = Store.list(store, prefix)
      Enum.map(objects, & &1.key)
    end

    test "old flights below the newest whole base go, records and directories", %{
      store: store,
      day: day,
      now: now
    } do
      assert {:ok, 3} = Lease.retire(store, "a", now, day, bases([1, 2, 4]))
      assert {:ok, [4, 5, 6]} = Lease.flights(store, "a")

      for n <- 1..3, do: assert(keys(store, Layout.flight_data("a", n) <> "/") == [])
      assert keys(store, Layout.flight_data("a", 4) <> "/") != []

      assert {:ok, [1, 2]} = Lease.flights(store, "a/b")
      assert length(keys(store, "gliders/a/b/")) == 4
    end

    test "nothing at or above the newest whole base goes, however old", %{
      store: store,
      now: now
    } do
      assert {:ok, 2} = Lease.retire(store, "a", now, 1, bases([1, 3]))
      assert {:ok, [3, 4, 5, 6]} = Lease.flights(store, "a")

      assert {:ok, 0} = Lease.retire(store, "a", now, 1, bases([]))
      assert {:ok, [3, 4, 5, 6]} = Lease.flights(store, "a")
    end

    test "flights younger than older_than_ms stay", %{store: store, day: day, now: now} do
      assert {:ok, 0} = Lease.retire(store, "a", now, 4 * day, bases([4]))
      assert {:ok, [1, 2, 3, 4, 5, 6]} = Lease.flights(store, "a")

      # 3 ran out 30 s after 1 and 2 landed.
      cut = 3 * day - 15_000
      assert {:ok, 2} = Lease.retire(store, "a", now, cut, bases([4]))
      assert {:ok, [3, 4, 5, 6]} = Lease.flights(store, "a")
    end

    test "a flight whose record cannot be read is left alone", %{
      store: store,
      day: day,
      now: now
    } do
      put_raw(store, "a", 2, "garbage")
      assert {:ok, 2} = Lease.retire(store, "a", now, day, bases([4]))
      assert {:ok, [2, 4, 5, 6]} = Lease.flights(store, "a")
    end
  end

  # ------------------------------------------------------------------ failing

  describe "the store failing" do
    setup %{tmp_dir: dir} do
      store = store(dir)
      {:ok, lease} = Lease.take(store, "a", me(1), fixed(@t0), @timing, create: true)
      %{store: store, lease: lease}
    end

    defp all_fail(store, lease) do
      later = fixed(@t0 + 1)
      free = fixed(@t0 + 10 ** 7)

      results = [
        flights: Lease.flights(store, "a"),
        read: Lease.read(store, "a", 1),
        current: Lease.current(store, "a"),
        take: Lease.take(store, "a", me(2), free, @timing),
        take_own: Lease.take(store, "a", me(1), later, @timing, takeover_own: true),
        create: Lease.take(store, "a", me(2), later, @timing, create: true),
        renew: Lease.renew(store, lease, later, @timing),
        update: Lease.update(store, lease, [shipped: nil], later, @timing),
        land: Lease.land(store, lease, nil, later, @timing),
        source: Lease.source(store, "a", 2, bases([1])),
        retire: Lease.retire(store, "a", free, 1, bases([1]))
      ]

      for {name, result} <- results do
        assert {:error, reason} = result, "#{name}: #{inspect(result)}"
        refute reason in [:lost, :not_found], "#{name} said #{inspect(reason)}"
      end
    end

    test "an unreadable flights directory is an error from every function", %{
      store: store,
      lease: lease,
      tmp_dir: dir
    } do
      if permissions_hold?(dir) do
        path = Path.join(store.config.root, Layout.flights_prefix("a"))
        File.chmod!(path, 0o000)

        try do
          all_fail(store, lease)
        after
          File.chmod!(path, 0o755)
        end

        assert {:ok, ^lease} = Lease.current(store, "a")
      end
    end

    test "a store whose root has gone from under it is an error, not a free glider", %{
      store: store,
      lease: lease,
      tmp_dir: dir
    } do
      file = Path.join(dir, "plain")
      File.write!(file, "x")
      gone = %{store | config: %{store.config | root: Path.join(file, "store")}}

      assert {:error, _} =
               Lease.take(gone, "a", me(2), fixed(@t0 + 10 ** 7), @timing, create: true)

      assert {:error, _} = Lease.renew(gone, lease, fixed(@t0 + 1), @timing)
      refute match?({:ok, _}, Lease.take(gone, "a", me(2), fixed(@t0 + 10 ** 7), @timing))
    end

    test "a record that cannot be read for want of permission is an error, not lost", %{
      store: store,
      lease: lease,
      tmp_dir: dir
    } do
      if permissions_hold?(dir) do
        path = Path.join(store.config.root, Layout.flight_record("a", 1))
        File.chmod!(path, 0o000)

        try do
          assert {:error, reason} = Lease.renew(store, lease, fixed(@t0 + 1), @timing)
          assert is_binary(reason)
          assert {:error, reason} = Lease.current(store, "a")
          assert is_binary(reason)
          assert {:error, _} = Lease.take(store, "a", me(2), fixed(@t0 + 10 ** 7), @timing)
          assert {:error, _} = Lease.read(store, "a", 1)
        after
          File.chmod!(path, 0o644)
        end
      end
    end
  end
end
