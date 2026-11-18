defmodule Aerotow.RouterTest do
  use ExUnit.Case, async: false

  import Aerotow.TowCase

  alias Aerotow.{Card, Catalog, Instance, Lease, Options, Router, Server, Store}
  alias Aerotow.Store.Layout

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"

  defp instance!(tow) do
    {:ok, instance} = Instance.fetch(tow)
    instance
  end

  defp store!(tow, name) do
    {:ok, store} = Server.store(instance!(tow), name)
    store
  end

  # Takes the next flight of `ref` as some instance with no process behind it.
  defp take(store, ref, id) do
    me = %{id: id, node: "elsewhere@host", url: "https://elsewhere.example.com/aerotow"}

    {:ok, lease} =
      Lease.take(store, ref, me, :system, %{ttl: 300_000, margin: 5_000, grace: 5_000})

    lease
  end

  describe "2: routing" do
    setup %{tmp_dir: dir} do
      tow =
        tow(Path.join(dir, "a"),
          stores: [
            {"store", Path.join(dir, "store")},
            {"disk", Path.join(dir, "disk"), kind: :file}
          ],
          default_store: "store"
        )

      %{tow: tow}
    end

    test "aloft here runs here; hangared in a dir store launches here", %{tow: tow} do
      {:ok, _} = Aerotow.create(tow, @ref)
      assert {:ok, {:here, pid}} = Router.locate(instance!(tow), @ref)
      assert is_pid(pid)
      :ok = Aerotow.land(tow, @ref)

      store = store!(tow, "store")
      assert {:ok, {:launch, ^store}} = Router.locate(instance!(tow), @ref)
      assert {:ok, :hangared} = Aerotow.where(tow, @ref)
      assert {:ok, _} = Aerotow.query(tow, @ref, "STATS")
      assert {:ok, :here} = Aerotow.where(tow, @ref)
    end

    test "a glider in a file store is launched here, opened where it lies", %{
      tow: tow,
      tmp_dir: dir
    } do
      {:ok, card} = Aerotow.create(tow, "local/one", store: "disk")
      assert card.store == "disk"
      {:ok, 1} = Aerotow.run(tow, "local/one", "CREATE (:N)")
      :ok = Aerotow.land(tow, "local/one")
      assert File.exists?(Path.join([dir, "disk", "local", "one.gldb"]))

      disk = store!(tow, "disk")
      assert {:ok, {:launch, ^disk}} = Router.locate(instance!(tow), "local/one")

      assert {:ok, %{rows: [[1]]}} =
               Aerotow.query(tow, "local/one", "MATCH (n:N) RETURN count(n)")
    end

    test "a glider whose current flight is somebody else's and active is aloft elsewhere, named",
         %{tow: tow} do
      {:ok, _} = Aerotow.create(tow, @ref)
      :ok = Aerotow.land(tow, @ref)
      other = String.duplicate("c", 32)
      lease = take(store!(tow, "store"), @ref, other)

      holder = %{
        holder: other,
        node: "elsewhere@host",
        url: "https://elsewhere.example.com/aerotow",
        flight: lease.n
      }

      assert Aerotow.query(tow, @ref, "STATS") == {:error, {:aloft_elsewhere, holder}}
      assert Aerotow.run(tow, @ref, "CREATE (:N)") == {:error, {:aloft_elsewhere, holder}}
      assert Aerotow.checkout(tow, @ref, & &1) == {:error, {:aloft_elsewhere, holder}}
      assert Aerotow.where(tow, @ref) == {:ok, {:elsewhere, holder}}
      assert {:ok, []} = Aerotow.aloft(tow)

      {:ok, _} =
        Lease.land(store!(tow, "store"), lease, nil, :system, %{
          ttl: 300_000,
          margin: 5_000,
          grace: 5_000
        })

      assert {:ok, _} = Aerotow.query(tow, @ref, "STATS")
    end

    test "an active flight of this instance's own with no process behind it is not elsewhere: it is taken over",
         %{tow: tow} do
      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, 1} = Aerotow.run(tow, @ref, "CREATE (:N {n: 1})")
      :ok = Aerotow.land(tow, @ref)
      _dead = take(store!(tow, "store"), @ref, instance!(tow).id)

      assert {:ok, :hangared} = Aerotow.where(tow, @ref)
      assert rows(Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n")) == [[1]]
    end

    test "a glider homed in a peer store is not run here: :peer_not_supported", %{tow: tow} do
      instance = instance!(tow)

      peer = %Store{
        name: "west",
        kind: :peer,
        url: "https://west.example.com/aerotow",
        mod: Aerotow.Store.Peer
      }

      {:ok, spec} = Options.store({"west", "https://west.example.com/aerotow", token: "t"})
      :ok = Server.attach_store(instance, peer, spec)
      {:ok, card} = Card.new("west/thing")
      :ok = Catalog.put_card(instance.catalog, %{card | store: "west"})

      assert Aerotow.query(tow, "west/thing", "STATS") == {:error, :peer_not_supported}
      assert Aerotow.run(tow, "west/thing", "CREATE (:N)") == {:error, :peer_not_supported}
      assert Aerotow.where(tow, "west/thing") == {:ok, {:peer, "west"}}
      assert Aerotow.create(tow, "west/new", store: "west") == {:error, :peer_not_supported}
    end

    test "a glider homed in a store that cannot be reached is :store_unavailable", %{tow: tow} do
      instance = instance!(tow)
      {:ok, card} = Card.new("gone/thing")
      :ok = Catalog.put_store(instance.catalog, %{name: "gone", kind: :dir, url: "/nowhere"})
      :ok = Catalog.put_card(instance.catalog, %{card | store: "gone"})

      assert {:error, {:store_unavailable, "gone", _}} = Aerotow.query(tow, "gone/thing", "STATS")
    end
  end

  describe "3: R3, a miss is looked up" do
    test "R3: two instances on one bucket: one creates x, the other asks for it at once, with no scan",
         %{tmp_dir: dir} do
      {_fake, s3} = s3()
      stores = [{"assets", "s3://graphs/gliders", s3}]
      a = tow(Path.join(dir, "a"), stores: stores, default_store: "assets")
      b = tow(Path.join(dir, "b"), stores: stores, default_store: "assets")

      {:ok, _} = Aerotow.create(a, @ref, tags: ["code"])
      {:ok, 1} = Aerotow.run(a, @ref, "CREATE (:N {n: 1})")

      a_id = instance!(a).id

      assert {:error, {:aloft_elsewhere, %{holder: ^a_id}}} =
               Aerotow.query(b, @ref, "MATCH (n:N) RETURN n.n")

      assert {:ok, %{ref: @ref, tags: ["code"], store: "assets"}} = Aerotow.card(b, @ref)

      :ok = Aerotow.land(a, @ref)
      assert rows(Aerotow.query(b, @ref, "MATCH (n:N) RETURN n.n")) == [[1]]
    end

    test "R3: a ref is looked for in the stores in the order they were given", %{tmp_dir: dir} do
      first = Path.join(dir, "first")
      second = Path.join(dir, "second")
      {:ok, s1} = Store.new("first", first)
      {:ok, s2} = Store.new("second", second)
      {:ok, card} = Card.new("x", description: "in both")
      :ok = Store.write_card(s2, %{card | description: "second"})
      :ok = Store.write_card(s1, %{card | description: "first"})

      tow = tow(Path.join(dir, "a"), stores: [{"first", first}, {"second", second}])
      assert {:ok, %{description: "first", store: "first"}} = Aerotow.card(tow, "x")
      assert Aerotow.card(tow, "y") == {:error, :not_found}
      assert Aerotow.query(tow, "y", "STATS") == {:error, :not_found}
    end
  end

  describe "4: one flight per glider per instance" do
    setup %{tmp_dir: dir} do
      tow =
        tow(Path.join(dir, "a"),
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store"
        )

      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:N {n: 1})")
      :ok = Aerotow.land(tow, @ref)
      %{tow: tow}
    end

    test "many callers of a hangared glider start one flight and are all answered from it", %{
      tow: tow
    } do
      listen([[:aerotow, :launch, :start]])

      answers =
        1..24
        |> Task.async_stream(fn _ -> Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n") end,
          max_concurrency: 24,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, answer} -> rows(answer) end)

      assert Enum.all?(answers, &(&1 == [[1]]))
      assert_received {:telemetry, [:aerotow, :launch, :start], _, %{ref: @ref}}
      refute_received {:telemetry, [:aerotow, :launch, :start], _, %{ref: @ref}}
      assert {:ok, [%{ref: @ref}]} = Aerotow.aloft(tow)
    end

    test "a launch that fails answers every waiting caller with its reason and leaves nothing running",
         %{tow: tow} do
      # The only base there is, made unreadable: the launch restores it and
      # cannot open it.
      {url, _opts} = Store.replica(store!(tow, "store"), Layout.flight_data(@ref, 1))
      [db | _] = Path.wildcard(Path.join(url, "*/base/*/db"))
      File.write!(db, "not a database")

      answers =
        1..12
        |> Task.async_stream(fn _ -> Aerotow.query(tow, @ref, "STATS") end,
          max_concurrency: 12,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.all?(answers, &match?({:error, {:launch, _}}, &1))
      assert {:ok, []} = Aerotow.aloft(tow)
      instance = instance!(tow)
      assert Registry.lookup(instance.registry, @ref) == []
      assert DynamicSupervisor.count_children(instance.flights).active == 0
      assert Path.wildcard(Path.join([instance.dir, "flights", "**", "*.gldb"])) == []
    end
  end

  describe "5: two instances, one store" do
    for kind <- [:dir, :s3] do
      @tag kind: kind
      test "#{kind}: B is told A holds x until A lands, then launches and sees every write A made, and the two never fly x at once",
           %{tmp_dir: dir, kind: kind} do
        stores =
          case kind do
            :dir ->
              [{"store", Path.join(dir, "store")}]

            :s3 ->
              {_fake, s3} = s3()
              [{"store", "s3://graphs/gliders", s3}]
          end

        a = tow(Path.join(dir, "a"), stores: stores, default_store: "store")
        b = tow(Path.join(dir, "b"), stores: stores, default_store: "store")
        listen([[:aerotow, :launch, :stop], [:aerotow, :land, :stop]])

        {:ok, _} = Aerotow.create(a, @ref)
        for n <- 1..5, do: {:ok, 1} = Aerotow.run(a, @ref, "CREATE (:N {n: $n})", %{n: n})

        a_id = instance!(a).id

        assert {:error, {:aloft_elsewhere, %{holder: ^a_id, flight: 1}}} =
                 Aerotow.query(b, @ref, "STATS")

        assert {:error, {:aloft_elsewhere, _}} = Aerotow.run(b, @ref, "CREATE (:N {n: 6})")

        :ok = Aerotow.land(a, @ref)

        assert rows(Aerotow.query(b, @ref, "MATCH (n:N) RETURN n.n ORDER BY n.n")) ==
                 [[1], [2], [3], [4], [5]]

        {:ok, 1} = Aerotow.run(b, @ref, "CREATE (:N {n: 6})")
        b_id = instance!(b).id

        assert {:error, {:aloft_elsewhere, %{holder: ^b_id, flight: 2}}} =
                 Aerotow.query(a, @ref, "STATS")

        :ok = Aerotow.land(b, @ref)
        assert length(rows(Aerotow.query(a, @ref, "MATCH (n:N) RETURN n.n"))) == 6
        :ok = Aerotow.land(a, @ref)

        events = flights_in_order(@ref)

        assert events == [
                 {:launch, 1},
                 {:land, 1},
                 {:launch, 2},
                 {:land, 2},
                 {:launch, 3},
                 {:land, 3}
               ]
      end
    end
  end

  # The launches and landings of `ref`, in the order they happened.
  defp flights_in_order(ref, acc \\ []) do
    receive do
      {:telemetry, [:aerotow, what, :stop], _, %{ref: ^ref, flight: n}} ->
        flights_in_order(ref, [{what, n} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
