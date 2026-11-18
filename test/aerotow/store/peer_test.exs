defmodule Aerotow.Store.PeerTest do
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import Aerotow.PeerCase

  alias Aerotow.{Catalog, Instance, Server, Store}
  alias Aerotow.Store.Peer

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "west/code"

  # West: an aerotow with a dir store, served over HTTP. Here: an aerotow
  # whose stores are a dir of its own and west, as a peer store.
  defp pair(dir, peer_opts \\ []) do
    west =
      tow(Path.join(dir, "west"),
        stores: [{"wdisk", Path.join(dir, "wdisk")}],
        default_store: "wdisk"
      )

    url = serve(west)

    here =
      tow(Path.join(dir, "here"),
        stores: [
          {"local", Path.join(dir, "local")},
          {"west", url, Keyword.merge([token: token()], peer_opts)}
        ],
        default_store: "local"
      )

    %{west: west, here: here, url: url}
  end

  defp seed(west) do
    {:ok, _} = Aerotow.create(west, @ref, description: "west's code", tags: ["code"])

    {:ok, 3} =
      Aerotow.run(
        west,
        @ref,
        ~S|CREATE (:Module {name: "Aerotow", size: 3.0, tags: ["a", "ü"], text: "{\"_e\": \"node\"}"})-[:CALLS {w: 1}]->(:Module {name: "Glider", size: 12})|
      )

    {:ok, _} = Aerotow.create(west, "west/docs", tags: ["docs"])
    :ok
  end

  defp normal({:ok, %Aerotow.Card{} = card}), do: {:ok, %{card | store: nil, aloft: false}}
  defp normal(other), do: other

  describe "3: a peer store" do
    setup %{tmp_dir: dir} do
      %{west: west} = p = pair(dir)
      seed(west)
      p
    end

    test "3: the store is made from an http url and a token, and is available, with the peer's id",
         %{here: here, west: west} do
      {:ok, stores} = Aerotow.stores(here)

      assert %{name: "west", kind: :peer, available: true} =
               Enum.find(stores, &(&1.name == "west"))

      {:ok, store} = Server.store(Instance.fetch!(here), "west")
      assert store.config.id == Instance.fetch!(west).id
      refute inspect(store) =~ token()
    end

    test "3: a scan pages through the peer's gliders and puts its cards in the catalog, homed in the peer store",
         %{here: here} do
      assert {:ok, %{seen: 2, added: 2}} = Aerotow.scan(here, "west")

      assert {:ok, %{rows: [["west/code", "west"], ["west/docs", "west"]]}} =
               Aerotow.find(
                 here,
                 "MATCH (g:Glider)-[:HOMED_IN]->(s:Store) RETURN g.ref, s.name ORDER BY g.ref"
               )

      assert {:ok, [%{ref: @ref, card: %{store: "west"}} | _]} = Aerotow.search(here, "code")

      assert {:ok, %{gliders: [%{ref: @ref}, %{ref: "west/docs"}]}} =
               Aerotow.gliders(here, store: "west")

      assert {:ok, {:peer, "west"}} = Aerotow.where(here, @ref)
    end

    test "3: a scan reads each page once, not each card again", %{here: here} do
      listen([[:aerotow, :plug, :stop]])
      {:ok, %{added: 2}} = Aerotow.scan(here, "west")

      ops =
        Stream.repeatedly(fn ->
          receive do
            {:telemetry, [:aerotow, :plug, :stop], _, %{op: op}} -> op
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      assert ops == ["gliders"]
    end

    test "3: statements for a peer's glider are forwarded and answer as the peer answered",
         %{here: here, west: west} do
      {:ok, _} = Aerotow.scan(here, "west")
      cypher = "MATCH (m:Module)-[c:CALLS]->(o) RETURN m, c, o, m.size, m.tags, m.text"

      assert Aerotow.query(here, @ref, cypher, %{}, graph: true) ==
               Aerotow.query(west, @ref, cypher, %{}, graph: true)

      {:ok, %{rows: [[%Glider.Node{}, %Glider.Rel{}, %Glider.Node{}, 3.0, ["a", "ü"], text]]}} =
        Aerotow.query(here, @ref, cypher)

      assert text == ~S|{"_e": "node"}|

      assert {:ok, 1} = Aerotow.run(here, @ref, "CREATE (:Module {name: $n})", %{n: "Req"})

      assert {:ok, 2} =
               Aerotow.write_batch(here, @ref, [
                 {"CREATE (:Module {name: $n})", %{n: "Plug"}},
                 {"CREATE (:Module {name: $n})", %{"n" => "Bandit"}}
               ])

      assert {:ok, %{rows: [[5]]}} =
               Aerotow.query(west, @ref, "MATCH (m:Module) RETURN count(m)")

      assert Aerotow.schema(here, @ref) == Aerotow.schema(west, @ref)
      assert Aerotow.stats(here, @ref) == Aerotow.stats(west, @ref)

      # The context extension: refused alike before it is installed, answered
      # alike after.
      assert {:error, _} = no_context = Aerotow.context(west, @ref, query: "Aerotow")
      assert Aerotow.context(here, @ref, query: "Aerotow") == no_context
      {:ok, _} = Aerotow.run(here, @ref, "CREATE EXTENSION IF NOT EXISTS context")
      {:ok, _} = Aerotow.run(here, @ref, "CALL context.index()")

      assert {:ok, %{text: _}} =
               context = Aerotow.context(here, @ref, query: "Aerotow", budget: 200)

      assert context == Aerotow.context(west, @ref, query: "Aerotow", budget: 200)

      # What is refused there is refused the same.
      assert Aerotow.query(here, @ref, "MATCH (n) RETURN nothing(") ==
               Aerotow.query(west, @ref, "MATCH (n) RETURN nothing(")
    end

    test "3: card, create, update and delete for a peer's glider are forwarded",
         %{here: here, west: west} do
      {:ok, _} = Aerotow.scan(here, "west")
      assert normal(Aerotow.card(here, @ref)) == normal(Aerotow.card(west, @ref))
      assert {:ok, %{store: "west"}} = Aerotow.card(here, @ref)

      assert {:ok, %{ref: "west/new", store: "west", tags: ["new"]}} =
               Aerotow.create(here, "west/new",
                 store: "west",
                 tags: ["new"],
                 description: "made here"
               )

      assert {:ok, %{description: "made here", store: "wdisk"}} = Aerotow.card(west, "west/new")
      assert {:ok, %{store: "west"}} = Catalog.card(Instance.fetch!(here).catalog, "west/new")
      assert Aerotow.create(here, "west/new", store: "west") == {:error, :exists}

      assert {:ok, %{description: "changed", store: "west"}} =
               Aerotow.update(here, @ref, description: "changed")

      assert {:ok, %{description: "changed"}} = Aerotow.card(west, @ref)

      {:ok, %{rows: [[desc]]}} =
        Aerotow.find(here, "MATCH (g:Glider {ref: $ref}) RETURN g.description", %{ref: @ref})

      assert desc == "changed"

      assert :ok = Aerotow.delete(here, "west/new", purge: true)
      assert Aerotow.card(west, "west/new") == {:error, :not_found}
      assert Aerotow.card(here, "west/new") == {:error, :not_found}
      assert Catalog.card(Instance.fetch!(here).catalog, "west/new") == {:error, :not_found}
    end

    test "3: a peer's glider is looked up at the peer on a miss, with no scan (R3)", %{here: here} do
      assert {:ok, %{rows: [[2]]}} = Aerotow.query(here, @ref, "MATCH (m:Module) RETURN count(m)")
      assert {:ok, %{store: "west"}} = Catalog.card(Instance.fetch!(here).catalog, @ref)
      assert Aerotow.query(here, "west/none", "STATS") == {:error, :not_found}
    end

    test "3: checkout, launch and describe of a peer's glider are refused: it runs there",
         %{here: here} do
      {:ok, _} = Aerotow.scan(here, "west")
      assert Aerotow.checkout(here, @ref, & &1) == {:error, {:runs_on_peer, "west"}}
      assert Aerotow.launch(here, @ref) == {:error, {:runs_on_peer, "west"}}
      assert Aerotow.describe(here, @ref) == {:error, {:runs_on_peer, "west"}}
      assert {:ok, []} = Aerotow.aloft(here)
    end

    test "3: a peer lists only the gliders in its own stores, not those it knows through its peers",
         %{here: here, west: west, tmp_dir: dir} do
      # A third aerotow that peers with here: it sees here's own gliders,
      # and not west's, which here only knows through west.
      {:ok, _} = Aerotow.scan(here, "west")
      {:ok, _} = Aerotow.create(here, "here/own")
      third = tow(Path.join(dir, "third"), stores: [{"here", serve(here), token: token()}])
      {:ok, _} = Aerotow.scan(third, "here")
      {:ok, %{gliders: listed}} = Aerotow.gliders(third)
      assert Enum.map(listed, & &1.ref) == ["here/own"]
      assert {:ok, _} = Aerotow.card(west, @ref)
    end
  end

  describe "8: failures are answers" do
    test "8: a peer that is down: the store is unavailable at start and calls answer why", %{
      tmp_dir: dir
    } do
      url = "http://127.0.0.1:#{closed_port()}/aerotow"
      here = tow(Path.join(dir, "here"), stores: [{"west", url, token: token()}])
      {:ok, [%{available: false, reason: reason}]} = Aerotow.stores(here)
      assert reason =~ "could not be reached"
      refute reason =~ token()
    end

    test "8: a peer that goes down after the store was made: reads and writes both say so", %{
      tmp_dir: dir
    } do
      west =
        tow(Path.join(dir, "west"),
          stores: [{"wdisk", Path.join(dir, "wdisk")}],
          default_store: "wdisk"
        )

      url = serve(west, id: :west_server)

      here =
        tow(Path.join(dir, "here"), stores: [{"west", url, token: token(), attempts: 2}])

      seed(west)
      {:ok, _} = Aerotow.scan(here, "west")
      :ok = stop_supervised(:west_server)

      assert {:error, {:peer_unavailable, "west", why}} = Aerotow.query(here, @ref, "STATS")
      assert why =~ "could not be reached"
      # Refused before it was sent: not an unknown outcome.
      assert {:error, {:peer_unavailable, "west", _}} = Aerotow.run(here, @ref, "CREATE (:N)")
    end

    test "8: a slow peer: a read is tried attempts: times, a write once, and a lost write is an unknown outcome" do
      id = String.duplicate("a", 32)
      test = self()

      url =
        stub(fn
          %{method: "GET"} = conn ->
            hello(conn, id)

          conn ->
            send(test, {:hit, conn.path_info})

            # Held past the client's receive_timeout, then let go.
            receive do
              :never -> conn
            after
              1_000 -> Plug.Conn.send_resp(conn, 504, "late")
            end
        end)

      {:ok, store} = Store.new("west", url, token: token(), receive_timeout: 150, attempts: 3)

      assert {:error, {:peer_unavailable, "west", why}} =
               Peer.call(store, {:query, "a/b", "STATS", %{}, []}, 1)

      assert why =~ "did not answer within 150 ms"
      for _ <- 1..3, do: assert_receive({:hit, ["aerotow", "v1", "query"]})
      refute_receive {:hit, _}, 50

      assert {:error, {:outcome_unknown, "west", why}} =
               Peer.call(store, {:run, "a/b", "CREATE (:N)", %{}, []}, 1)

      assert why =~ "may or may not have been applied"
      assert_receive {:hit, ["aerotow", "v1", "run"]}
      refute_receive {:hit, _}, 300
    end

    test "8: a peer that answers 500, or garbage, or as another aerotow" do
      id = String.duplicate("a", 32)
      other = String.duplicate("b", 32)
      test = self()

      answers = %{
        "500" => fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end,
        "garbage" => fn conn ->
          Plug.Conn.put_resp_header(conn, "aerotow-id", id) |> Plug.Conn.send_resp(200, "<html>")
        end,
        "shape" => fn conn -> json(conn, 200, %{"columns" => "no"}, id) end,
        "other" => fn conn -> json(conn, 200, %{"touched" => 1}, other) end
      }

      for {label, answer} <- answers do
        url =
          stub(fn
            %{method: "GET"} = conn ->
              hello(conn, id)

            conn ->
              send(test, {:hit, label})
              answer.(conn)
          end)

        {:ok, store} = Store.new("west", url, token: token(), attempts: 2)
        read = Peer.call(store, {:query, "a/b", "STATS", %{}, []}, 1)
        assert {:error, {:peer_unavailable, "west", why}} = read, label
        assert is_binary(why)

        hits = if label == "500", do: 2, else: 1
        for _ <- 1..hits, do: assert_receive({:hit, ^label})
        refute_receive {:hit, ^label}, 20

        write = Peer.call(store, {:run, "a/b", "CREATE (:N)", %{}, []}, 1)
        assert_receive {:hit, ^label}
        refute_receive {:hit, ^label}, 20

        case label do
          "500" ->
            assert {:error, {:outcome_unknown, "west", _}} = write

          "other" ->
            assert {:error, {:peer_unavailable, "west", "it answered as the aerotow " <> _}} =
                     write

          _ ->
            assert {:error, {:peer_unavailable, "west", _}} = write
        end
      end
    end

    test "8: a peer store's url with a password in it, a missing token, or a peer that refuses the token" do
      secret = "pw-#{System.unique_integer([:positive])}"

      assert {:error, reason} =
               Store.new("west", "http://u:#{secret}@127.0.0.1:1/aerotow", token: "t")

      refute reason =~ secret
      assert {:error, reason} = Store.new("west", "http://127.0.0.1:1/aerotow")
      assert reason =~ "token"

      url = stub(fn conn -> json(conn, 401, %{"error" => "no", "code" => "unauthorized"}) end)
      assert {:error, reason} = Store.new("west", url, token: secret)
      assert reason =~ "refused the token"
      refute reason =~ secret
    end
  end

  # A port nothing listens on.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
