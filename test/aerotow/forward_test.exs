defmodule Aerotow.ForwardTest do
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import Aerotow.PeerCase

  alias Aerotow.{Card, Catalog, Forward, Instance}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"

  defp holder_of(tow), do: Instance.fetch!(tow).id

  describe "4: forwarding to a holder over HTTP" do
    setup %{tmp_dir: dir} do
      store = {"store", Path.join(dir, "store")}

      # B is served over HTTP; its flight records carry that url.
      b = name("b")
      b_url = serve(b)
      ^b = tow(Path.join(dir, "b"), name: b, url: b_url, stores: [store], default_store: "store")

      # A has the same store, and B as a peer store: so a token for B's url.
      a =
        tow(Path.join(dir, "a"),
          stores: [store, {"b", b_url, token: token()}],
          default_store: "store"
        )

      {:ok, _} = Aerotow.create(b, @ref, tags: ["code"])
      {:ok, 3} = Aerotow.run(b, @ref, "CREATE (:N {n: 1.0})-[:R]->(:N {n: 2})")
      %{a: a, b: b, b_url: b_url, dir: dir}
    end

    test "4: a statement for a glider B holds goes to B and answers as B does", %{a: a, b: b} do
      listen([[:aerotow, :forward, :start], [:aerotow, :forward, :stop]])
      cypher = "MATCH (x)-[r]->(y) RETURN x, r, y, x.n"

      assert Aerotow.query(a, @ref, cypher, %{}, graph: true) ==
               Aerotow.query(b, @ref, cypher, %{}, graph: true)

      assert_receive {:telemetry, [:aerotow, :forward, :start], _,
                      %{ref: @ref, op: :query, via: :http}}

      assert_receive {:telemetry, [:aerotow, :forward, :stop], %{duration: _},
                      %{ref: @ref, op: :query, via: :http, result: :ok}}

      assert {:ok, 1} = Aerotow.run(a, @ref, "CREATE (:N {n: 3})")
      assert {:ok, 1} = Aerotow.write_batch(a, @ref, [{"CREATE (:N {n: $n})", %{n: 4}}])
      assert {:ok, %{rows: [[4]]}} = Aerotow.query(b, @ref, "MATCH (n:N) RETURN count(n)")
      assert Aerotow.stats(a, @ref) == Aerotow.stats(b, @ref)
      assert Aerotow.schema(a, @ref) == Aerotow.schema(b, @ref)

      assert {:ok, %{description: "held by b"}} =
               Aerotow.update(a, @ref, description: "held by b")

      assert {:ok, %{description: "held by b"}} = Aerotow.card(b, @ref)

      # Nothing was launched on A; B kept its one flight.
      assert {:ok, []} = Aerotow.aloft(a)
      assert {:ok, [%{ref: @ref}]} = Aerotow.aloft(b)
    end

    test "4: what runs only where the glider is open is still refused, named", %{a: a, b: b} do
      b_id = holder_of(b)
      assert {:error, {:aloft_elsewhere, %{holder: ^b_id}}} = Aerotow.checkout(a, @ref, & &1)
      assert {:error, {:aloft_elsewhere, %{holder: ^b_id}}} = Aerotow.launch(a, @ref)
    end

    test "4: with no peer store for the holder's url, the call is aloft elsewhere, as before",
         %{b: b, dir: dir} do
      c = tow(Path.join(dir, "c"), stores: [{"store", Path.join(dir, "store")}])
      b_id = holder_of(b)
      assert {:error, {:aloft_elsewhere, %{holder: ^b_id}}} = Aerotow.query(c, @ref, "STATS")
    end

    test "4: the receiver's rules hold for a forwarded statement", %{a: a, b: b} do
      # Sent as B would get it, past A's own checks.
      {:ok, holder} = Aerotow.where(a, @ref)
      {:elsewhere, holder} = holder
      instance = Instance.fetch!(a)

      assert {:error, refused} =
               Forward.to_holder(instance, holder, {:query, @ref, "CREATE (:N)", %{}, []})

      assert refused =~ "run/5"

      assert {:error, refused} =
               Forward.to_holder(instance, holder, {:run, @ref, "BEGIN", %{}, []})

      assert refused =~ "checkout"
      assert {:ok, %{rows: [[2]]}} = Aerotow.query(b, @ref, "MATCH (n:N) RETURN count(n)")
    end
  end

  describe "4: forwarding to a holder over distribution" do
    @describetag timeout: 120_000

    test "4: two nodes, one instance of the same name on each, one dir store: a call goes to the node that holds the glider",
         %{tmp_dir: dir} do
      listen([[:aerotow, :forward, :start], [:aerotow, :forward, :stop]])
      other = peer_node!("aerotow_b")
      name = name("dist")
      store = {"store", Path.join(dir, "store")}

      opts = fn label ->
        [
          name: name,
          dir: Path.join(dir, label),
          stores: [store],
          default_store: "store",
          scan_interval: nil,
          idle: :infinity,
          sync_interval: 3_600_000,
          timing: %{ttl: 300_000, margin: 5_000, grace: 5_000}
        ]
      end

      {:ok, _pid} = :erpc.call(other, Aerotow.PeerNode, :start_instance, [opts.("b")])
      {:ok, _} = :erpc.call(other, Aerotow, :create, [name, @ref, []])
      {:ok, 1} = :erpc.call(other, Aerotow, :run, [name, @ref, "CREATE (:N {n: 1.5})", %{}, []])

      ^name = tow(Path.join(dir, "a"), Keyword.drop(opts.("a"), [:dir]))

      other_name = Atom.to_string(other)
      assert {:ok, {:elsewhere, %{node: ^other_name}}} = Aerotow.where(name, @ref)

      assert {:ok, %{rows: [[1.5]]}} = Aerotow.query(name, @ref, "MATCH (n:N) RETURN n.n")

      assert_receive {:telemetry, [:aerotow, :forward, :stop], _,
                      %{ref: @ref, op: :query, via: :distribution, result: :ok}}

      assert {:ok, 1} = Aerotow.run(name, @ref, "CREATE (:N {n: 2})")

      assert {:ok, %{rows: [[2]]}} =
               :erpc.call(other, Aerotow, :query, [
                 name,
                 @ref,
                 "MATCH (n:N) RETURN count(n)",
                 %{},
                 []
               ])

      # The receiver's own check, over distribution too.
      assert {:error, refused} =
               :erpc.call(other, Forward, :serve, [
                 name,
                 {:query, @ref, "CREATE (:N)", %{}, []},
                 1
               ])

      assert refused =~ "run/5"
      assert {:ok, []} = Aerotow.aloft(name)

      # A node name is never made an atom: one that is not connected is
      # compared and passed over.
      holder = %{
        holder: String.duplicate("e", 32),
        node: "never_seen_#{System.unique_integer([:positive])}@nowhere",
        url: nil,
        flight: 1
      }

      before = :erlang.system_info(:atom_count)

      assert {:error, {:aloft_elsewhere, ^holder}} =
               Forward.to_holder(Instance.fetch!(name), holder, {:stats, @ref})

      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "5: loops end" do
    test "5: two instances that each believe the other has a glider stop after three hops",
         %{tmp_dir: dir} do
      a = name("a")
      b = name("b")
      a_url = serve(a)
      b_url = serve(b)
      ^a = tow(Path.join(dir, "a"), name: a)
      ^b = tow(Path.join(dir, "b"), name: b, stores: [{"a", a_url, token: token()}])
      {:ok, _} = Aerotow.add_store(a, "b", b_url, token: token())

      # Stale catalogs: each says the other has it.
      {:ok, card} = Card.new("loop/x")
      {:ok, _} = Aerotow.scan(b, "a")
      :ok = Catalog.put_card(Instance.fetch!(a).catalog, %{card | store: "b"})
      :ok = Catalog.put_card(Instance.fetch!(b).catalog, %{card | store: "a"})

      listen([[:aerotow, :plug, :stop], [:aerotow, :forward, :stop]])

      assert Aerotow.query(a, "loop/x", "STATS") == {:error, :too_many_hops}
      assert Aerotow.run(a, "loop/x", "CREATE (:N)") == {:error, :too_many_hops}

      # The query went a -> b -> a -> b, and b did not send it on.
      plug_stops =
        for _ <- 1..3 do
          assert_receive {:telemetry, [:aerotow, :plug, :stop], _, %{op: "query", status: status}}
          status
        end

      assert plug_stops == [508, 508, 508]
    end

    test "5: a call that arrives claiming more than three hops is refused before it runs" do
      assert Forward.serve(:any_tow, {:stats, "a"}, 4) == {:error, :too_many_hops}
      assert Forward.next_hop() == {:ok, 1}
    end
  end
end
