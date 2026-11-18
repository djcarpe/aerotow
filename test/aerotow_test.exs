defmodule AerotowTest do
  # Not async: instances start stores, which load code and make atoms, and
  # Aerotow.CardTest counts the VM's atoms while it runs.
  use ExUnit.Case, async: false

  import Aerotow.TowCase

  alias Aerotow.{Catalog, Flight, Instance, Lease, Store}
  alias Aerotow.Store.Layout

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"

  describe "1: the README's example" do
    test "runs as written, with the S3 fake for MinIO and a dir store for the peer", %{
      tmp_dir: dir
    } do
      {_fake, s3} = s3()

      children = [
        {Aerotow,
         name: MyApp.Aerotow,
         dir: Path.join(dir, "aerotow"),
         stores: [
           {"assets", "s3://graphs/gliders", s3},
           {"west", Path.join(dir, "west"), []}
         ],
         default_store: "assets"}
      ]

      Enum.each(children, &start_supervised!/1)

      tow = MyApp.Aerotow

      {:ok, _card} =
        Aerotow.create(tow, "engineering/code", description: "the code graph", tags: ["code"])

      {:ok, 3} =
        Aerotow.run(
          tow,
          "engineering/code",
          ~S|CREATE (:Module {name:"Aerotow"})-[:CALLS]->(:Module {name:"Glider"})|
        )

      # find: Cypher over the metadata
      {:ok, %{rows: [["engineering/code", "assets"]]}} =
        Aerotow.find(tow, """
        MATCH (g:Glider)-[:HAS_LABEL]->(:Label {name: "Module"}), (g)-[:HOMED_IN]->(s:Store)
        RETURN g.ref, s.name
        """)

      # interact: wherever it is
      {:ok, result} = Aerotow.query(tow, "engineering/code", "MATCH (m:Module) RETURN m.name")

      assert Enum.sort(result.rows) == [["Aerotow"], ["Glider"]]
    end
  end

  describe "starting" do
    test "unknown options, a missing name or dir, and a default_store that is not a store are errors",
         %{tmp_dir: dir} do
      assert {:error, reason} = Aerotow.start_link(name: name(), dir: dir, colour: :blue)
      assert reason =~ ":colour"
      assert {:error, _} = Aerotow.start_link(dir: dir)
      assert {:error, _} = Aerotow.start_link(name: name())

      assert {:error, reason} =
               Aerotow.start_link(name: name(), dir: dir, default_store: "nowhere")

      assert reason =~ "nowhere"

      assert {:error, _} =
               Aerotow.start_link(name: name(), dir: dir, timing: %{ttl: 300, margin: 250})

      assert {:error, _} = Aerotow.start_link(name: name(), dir: dir, id: "not hex")
    end

    test "one instance per dir: a second on the same dir fails, saying the directory is in use",
         %{tmp_dir: dir} do
      tow(dir)
      other = name()

      assert {:error, {reason, _child}} = start_supervised({Aerotow, name: other, dir: dir})
      assert reason =~ "in use"
      assert Process.whereis(other) == nil
    end

    test "the id is made and kept in instance.json, read back on a restart, and id: overrides it",
         %{tmp_dir: dir} do
      a = tow(dir)
      {:ok, %Instance{id: id}} = Instance.fetch(a)
      assert id =~ ~r/\A[0-9a-f]{32}\z/
      assert File.read!(Path.join(dir, "instance.json")) =~ id
      stop_supervised!(a)

      b = tow(dir)
      assert {:ok, %Instance{id: ^id}} = Instance.fetch(b)
      stop_supervised!(b)

      given = String.duplicate("ab", 16)
      c = tow(dir, id: given)
      assert {:ok, %Instance{id: ^given}} = Instance.fetch(c)
      assert File.read!(Path.join(dir, "instance.json")) =~ given
    end

    test "an instance that is not running answers :not_running" do
      assert Aerotow.query(:no_such_tow, @ref, "STATS") == {:error, :not_running}
      assert Aerotow.stores(:no_such_tow) == {:error, :not_running}
    end
  end

  describe "6: R17 and the statements" do
    setup %{tmp_dir: dir} do
      tow =
        tow(Path.join(dir, "a"),
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store"
        )

      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:N {n: 1})")
      %{tow: tow}
    end

    test "R17: query/5 refuses a write with Statement's message, and it never reaches the glider",
         %{tow: tow} do
      :ok = Aerotow.land(tow, @ref)
      listen([[:aerotow, :launch, :start]])

      for write <- [
            "CREATE (:N {n: 2})",
            "MATCH (n:N) SET n.n = 5",
            "MATCH (n) DETACH DELETE n",
            "CALL pagerank(write: \"rank\")",
            "BEGIN"
          ] do
        assert {:error, message} = Aerotow.query(tow, @ref, write)
        assert message =~ "Aerotow.run/5"
      end

      refute_received {:telemetry, [:aerotow, :launch, :start], _, _}
      assert {:ok, :hangared} = Aerotow.where(tow, @ref)
      assert rows(Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n")) == [[1]]
    end

    test "R17: find/3 refuses a write over the catalog", %{tow: tow} do
      assert {:error, message} = Aerotow.find(tow, "MATCH (g:Glider) DETACH DELETE g")
      assert message =~ "Aerotow.run/5"
      assert rows(Aerotow.find(tow, "MATCH (g:Glider) RETURN g.ref")) == [[@ref]]
    end

    test "run/5 and write_batch/3 refuse BEGIN, COMMIT and ROLLBACK in any case, spacing or after comments",
         %{tow: tow} do
      for control <- [
            "BEGIN",
            "begin",
            "  CoMmIt  ",
            "// a comment\nROLLBACK",
            ";;\n\tbegin",
            "`BEGIN`",
            "EXPLAIN BEGIN"
          ] do
        assert {:error, message} = Aerotow.run(tow, @ref, control), inspect(control)
        assert message =~ "checkout"

        assert {:error, _} =
                 Aerotow.write_batch(tow, @ref, [{"CREATE (:N)", %{}}, {control, %{}}])
      end

      {:ok, db_check} =
        Aerotow.checkout(tow, @ref, fn db -> Glider.in_transaction?(db) end)

      refute db_check
      assert {:ok, 1} = Aerotow.run(tow, @ref, "MATCH (begin:N) RETURN begin")
    end

    test "run/5 marks the flight written exactly when the statement writes; checkout/4 always does",
         %{tow: tow} do
      :ok = Aerotow.land(tow, @ref)

      assert {:ok, _} = Aerotow.run(tow, @ref, "MATCH (n:N) RETURN n")
      assert [%{ref: @ref, dirty: false}] = aloft!(tow)

      assert {:ok, 1} = Aerotow.run(tow, @ref, "CREATE (:N {n: 2})")
      assert [%{dirty: true}] = aloft!(tow)

      :ok = Aerotow.land(tow, @ref)
      assert {:ok, :read_only} = Aerotow.checkout(tow, @ref, fn _db -> :read_only end)
      assert [%{dirty: true}] = aloft!(tow)
    end

    test "a transaction is checkout/4 with Glider.transaction/2", %{tow: tow} do
      assert {:ok, {:ok, :done}} =
               Aerotow.checkout(tow, @ref, fn db ->
                 Glider.transaction(db, fn ->
                   {:ok, _} = Glider.run(db, "CREATE (:N {n: 7})")
                   :done
                 end)
               end)

      assert rows(Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n ORDER BY n.n")) == [[1], [7]]
    end

    test "write_batch/3 applies all or none", %{tow: tow} do
      assert {:ok, 2} =
               Aerotow.write_batch(tow, @ref, [
                 {"CREATE (:N {n: $n})", %{"n" => 2}},
                 {"CREATE (:N {n: $n})", %{"n" => 3}}
               ])

      assert {:error, _} =
               Aerotow.write_batch(tow, @ref, [
                 {"CREATE (:N {n: 4})", %{}},
                 {"CREATE (:N {n: 5", %{}}
               ])

      assert rows(Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n ORDER BY n.n")) ==
               [[1], [2], [3]]
    end

    test "context, schema and stats run on the glider", %{tow: tow} do
      assert {:ok, %{"nodes" => 1}} = Aerotow.stats(tow, @ref)
      assert {:ok, %{labels: [%{name: "N"} | _]}} = Aerotow.schema(tow, @ref)
      assert {:ok, :here} = Aerotow.where(tow, @ref)
    end
  end

  describe "7: bounded results" do
    test "query/5 passes max_rows:, max_bytes: and graph:, and a result over the cap is an error",
         %{tmp_dir: dir} do
      tow = tow(dir, stores: [{"store", Path.join(dir, "store")}], default_store: "store")
      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:N {n: 1}), (:N {n: 2}), (:N {n: 3})")

      assert length(rows(Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n"))) == 3

      assert {:error, reason} =
               Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n", %{}, max_rows: 2)

      assert reason =~ "cap"

      assert {:error, _} =
               Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n", %{}, max_bytes: 16)

      assert {:ok, %{graph: %{nodes: [_, _, _]}}} =
               Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n", %{}, graph: true)

      assert {:error, _} = Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n", %{}, colour: 1)
    end
  end

  describe "8: create, adopt, update, describe, card, delete" do
    setup %{tmp_dir: dir} do
      stores = [{"store", Path.join(dir, "store")}, {"other", Path.join(dir, "other")}]
      tow = tow(Path.join(dir, "a"), stores: stores, default_store: "store")
      %{tow: tow, stores: stores}
    end

    test "create/3 of a ref the catalog or any store knows is :exists", %{tow: tow, tmp_dir: dir} do
      assert {:ok, card} =
               Aerotow.create(tow, @ref, description: "the code graph", tags: ["code"])

      assert card.description == "the code graph"
      assert card.store == "store"
      assert {:error, :exists} = Aerotow.create(tow, @ref)
      assert {:error, :exists} = Aerotow.create(tow, @ref, store: "other")

      # Known only to a store: a card that this catalog has never seen.
      {:ok, other} = Store.new("other", Path.join(dir, "other"))
      {:ok, stray} = Aerotow.Card.new("public/site")
      :ok = Store.write_card(other, stray)
      assert {:error, :exists} = Aerotow.create(tow, "public/site")

      assert {:error, reason} = Aerotow.create(tow, "x", store: "nowhere")
      assert match?({:store_unavailable, "nowhere", _}, reason)
      assert {:error, _} = Aerotow.create(tow, "Not A Ref")
      assert {:error, _} = Aerotow.create(tow, "x", colour: "blue")
    end

    test "adopt/4 brings a database file in and leaves it as it was", %{tow: tow, tmp_dir: dir} do
      path = Path.join(dir, "old.gldb")
      {:ok, db} = Glider.open(path)
      {:ok, _} = Glider.run(db, "CREATE (:Old {n: 1})")
      Glider.close(db)
      before = File.read!(path)

      assert {:ok, card} = Aerotow.adopt(tow, "old/one", path, tags: ["old"])
      assert card.nodes == 1
      assert rows(Aerotow.query(tow, "old/one", "MATCH (o:Old) RETURN o.n")) == [[1]]
      assert File.read!(path) == before
    end

    test "update/3 and describe/2 of a hangared glider launch it, write the card through the flight, and leave it aloft",
         %{tow: tow, tmp_dir: dir} do
      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:A)-[:R]->(:B)")
      :ok = Aerotow.land(tow, @ref)
      assert {:ok, :hangared} = Aerotow.where(tow, @ref)

      assert {:ok, card} =
               Aerotow.update(tow, @ref, description: "changed", attrs: %{owner: "dj"})

      assert card.description == "changed"
      assert {:ok, :here} = Aerotow.where(tow, @ref)
      {:ok, store} = Store.new("store", Path.join(dir, "store"))

      assert {:ok, %{description: "changed", attrs: %{"owner" => "dj"}}} =
               Store.read_card(store, @ref)

      :ok = Aerotow.land(tow, @ref)
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:C)")
      :ok = Aerotow.land(tow, @ref)
      {:ok, _} = Aerotow.card(tow, @ref)

      assert {:ok, card} = Aerotow.describe(tow, @ref)
      assert card.nodes == 3
      assert {:ok, :here} = Aerotow.where(tow, @ref)
      assert {:error, _} = Aerotow.update(tow, @ref, nodes: 7)
    end

    test "card/2 is the flight's while aloft and the catalog's after", %{tow: tow} do
      {:ok, _} = Aerotow.create(tow, @ref, tags: ["code"])
      assert {:ok, %{aloft: true, tags: ["code"]}} = Aerotow.card(tow, @ref)
      :ok = Aerotow.land(tow, @ref)
      assert {:ok, %{aloft: false, tags: ["code"], store: "store"}} = Aerotow.card(tow, @ref)
      assert {:error, :not_found} = Aerotow.card(tow, "no/such")
    end

    test "delete/3 without purge forgets the glider here only, and a scan brings it back",
         %{tow: tow} do
      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:N {n: 1})")

      assert :ok = Aerotow.delete(tow, @ref)
      assert rows(Aerotow.find(tow, "MATCH (g:Glider {known: true}) RETURN g.ref")) == []
      assert {:ok, %{added: 1}} = Aerotow.scan(tow, "store")
      assert rows(Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n")) == [[1]]
      assert {:error, :not_found} = Aerotow.delete(tow, "no/such")
    end

    test "delete/3 with purge: true deletes the glider from its store, and nothing of it is left",
         %{tow: tow, tmp_dir: dir} do
      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, _} = Aerotow.create(tow, "#{@ref}/inner")
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:N {n: 1})")
      :ok = Aerotow.land(tow, @ref)
      {:ok, _} = Aerotow.query(tow, @ref, "MATCH (n) RETURN n")

      assert :ok = Aerotow.delete(tow, @ref, purge: true)

      {:ok, store} = Store.new("store", Path.join(dir, "store"))
      {:ok, %{objects: objects}} = Store.list(store, "")
      keys = Enum.map(objects, & &1.key)
      refute Enum.any?(keys, &String.starts_with?(&1, Layout.flights_prefix(@ref)))
      refute Layout.card(@ref) in keys
      # The glider under it is a glider of its own, and stays.
      assert Layout.card("#{@ref}/inner") in keys

      assert {:error, :not_found} = Aerotow.card(tow, @ref)
      assert {:error, :not_found} = Aerotow.query(tow, @ref, "STATS")
      assert {:ok, _} = Aerotow.create(tow, @ref)
    end
  end

  describe "the interface's own checks" do
    test "a ref that is not a ref, and a glider nobody has, are refused before anything runs", %{
      tmp_dir: dir
    } do
      tow = tow(dir, stores: [{"store", Path.join(dir, "store")}])
      assert {:error, reason} = Aerotow.query(tow, "../etc", "STATS")
      assert reason =~ "not a ref"
      assert Aerotow.query(tow, "no/such", "STATS") == {:error, :not_found}
      assert Aerotow.run(tow, "no/such", "CREATE (:N)") == {:error, :not_found}
      assert Aerotow.land(tow, "no/such") == {:error, :not_aloft}
      assert Aerotow.sync(tow, "no/such") == {:error, :not_aloft}
      assert {:error, _} = Aerotow.create(tow, "x")
    end

    test "catalog/1 is the catalog's handle, for reading", %{tmp_dir: dir} do
      tow = tow(dir, stores: [{"store", Path.join(dir, "store")}], default_store: "store")
      {:ok, _} = Aerotow.create(tow, @ref, tags: ["code"])
      assert {:ok, db} = Aerotow.catalog(tow)

      assert {:ok, %{rows: [[@ref]]}} =
               Glider.query(db, "MATCH (g:Glider {known: true}) RETURN g.ref")

      assert {:ok, %{gliders: [%{ref: @ref}]}} = Aerotow.gliders(tow, tag: "code")
      assert {:ok, [%{ref: @ref}]} = Aerotow.search(tow, "code")
    end

    test "sync/2 ships what a glider aloft here has not shipped", %{tmp_dir: dir} do
      tow = tow(dir, stores: [{"store", Path.join(dir, "store")}], default_store: "store")
      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:N)")
      assert {:ok, %{segments: segments}} = Aerotow.sync(tow, @ref)
      assert segments >= 1
      assert [%{dirty: false}] = aloft!(tow)

      {:ok, instance} = Instance.fetch(tow)
      {:ok, store} = Aerotow.Server.store(instance, "store")
      assert {:ok, %Lease{n: 1, holder: holder}} = Lease.current(store, @ref)
      assert holder == instance.id
      assert {:ok, _} = Catalog.card(instance.catalog, @ref)
      assert [_] = Registry.lookup(instance.registry, @ref)
      [{pid, _}] = Registry.lookup(instance.registry, @ref)
      assert %{state: :aloft} = Flight.info(pid)
    end
  end

  defp aloft!(tow) do
    {:ok, infos} = Aerotow.aloft(tow)
    infos
  end
end
