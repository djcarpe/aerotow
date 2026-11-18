defmodule Aerotow.WireTest do
  # Not async: one test counts the VM's atoms.
  use ExUnit.Case, async: false

  alias Aerotow.{Card, Wire}

  doctest Aerotow.Wire

  # Through JSON text and back, as a body crosses the wire.
  defp across(term), do: term |> JSON.encode!() |> JSON.decode!()

  # ------------------------------------------------------------------ generators

  @texts [
    "",
    "plain",
    "ünïcödé ✈ 滑翔机 🛩",
    ~s({"_e": "node", "id": 1, "labels": [], "props": {}}),
    ~s({"_e":"rel","id":1,"type":"T","from":1,"to":2,"props":{}}),
    ~s({"_e": "map", "v": {}}),
    "line\nbreak \"quoted\" \\ back",
    "\u0000\u001f control"
  ]

  defp scalar do
    case :rand.uniform(9) do
      1 -> nil
      2 -> :rand.uniform(2) == 1
      3 -> :rand.uniform(1_000_000) - 500_000
      4 -> Enum.random([0, -1, 9_223_372_036_854_775_807, -9_223_372_036_854_775_808])
      5 -> (:rand.uniform(2_000) - 1_000) * 1.0
      6 -> Enum.random([3.0, 0.5, -2.25, 1.0e300, 1.0e-300, 123_456.789])
      7 -> :rand.uniform() * 1.0e6
      _ -> Enum.random(@texts) <> Integer.to_string(:rand.uniform(9))
    end
  end

  # A property value: a scalar, or a list of them, nested.
  defp prop(0), do: scalar()

  defp prop(depth) do
    case :rand.uniform(4) do
      1 -> for _ <- 1..:rand.uniform(4)//1, do: prop(depth - 1)
      2 -> []
      _ -> scalar()
    end
  end

  defp props do
    for _ <- 1..:rand.uniform(5)//1, into: %{} do
      {Enum.random(@texts) <> "#{:rand.uniform(99)}", prop(3)}
    end
  end

  defp node_value,
    do: %Glider.Node{
      id: :rand.uniform(1_000_000) - 1,
      labels: Enum.take_random(["A", "Böse", "_e", "node"], :rand.uniform(3)),
      props: props()
    }

  defp rel_value,
    do: %Glider.Rel{
      id: :rand.uniform(1_000) - 1,
      type: Enum.random(["KNOWS", "rel", "_e"]),
      from: :rand.uniform(1_000) - 1,
      to: :rand.uniform(1_000) - 1,
      props: props()
    }

  # A cell: any value a query can return.
  defp cell(depth) do
    case :rand.uniform(6) do
      1 -> node_value()
      2 -> rel_value()
      3 when depth > 0 -> for _ <- 1..:rand.uniform(3)//1, do: cell(depth - 1)
      _ -> prop(2)
    end
  end

  defp result do
    width = :rand.uniform(4)

    %Glider.Result{
      columns: for(i <- 1..width, do: "c#{i} #{Enum.random(@texts)}"),
      rows: for(_ <- 1..:rand.uniform(6)//1, do: for(_ <- 1..width, do: cell(3))),
      graph: %{
        nodes: for(_ <- 1..:rand.uniform(3)//1, do: node_value()),
        edges: for(_ <- 1..:rand.uniform(3)//1, do: rel_value())
      },
      message: Enum.random([nil, "a message ✓"]),
      touched: :rand.uniform(10) - 1
    }
  end

  # ------------------------------------------------------------------ 2: the same terms

  describe "2: the same terms either way" do
    test "2: any query result crosses the wire and comes back equal", %{} do
      :rand.seed(:exsss, {2, 0, 26})

      for _ <- 1..400 do
        r = result()
        assert Wire.decode_answer(:query, across(Wire.encode_answer(:query, r))) == {:ok, r}
      end
    end

    test "2: any parameters cross the wire in a request and come back equal" do
      :rand.seed(:exsss, {2, 1, 26})

      for _ <- 1..400 do
        params = Map.new(1..:rand.uniform(4), fn i -> {"p#{i}", cell(2)} end)
        request = {:query, "a/b", "MATCH (n) RETURN n", params, [max_rows: 5]}
        {:ok, "query", body} = Wire.encode_request(request)
        assert Wire.decode_request(:query, across(body)) == {:ok, request}
      end
    end

    test "2: whole floats stay floats, integers stay integers, nested lists stay nested" do
      r = %Glider.Result{columns: ["x"], rows: [[3.0], [3], [[1, [2.0, [nil, "x"]]]], [-0.5]]}
      {:ok, back} = Wire.decode_answer(:query, across(Wire.encode_answer(:query, r)))
      assert back.rows == r.rows
      assert [[f], [i] | _] = back.rows
      assert is_float(f) and is_integer(i)
    end

    test "2: text that looks like a tagged object is text" do
      text = ~s({"_e": "node", "id": 7, "labels": ["X"], "props": {}})
      r = %Glider.Result{columns: ["t"], rows: [[text]]}

      assert {:ok, %{rows: [[^text]]}} =
               Wire.decode_answer(:query, across(Wire.encode_answer(:query, r)))
    end

    test "2: nodes and relationships come back as glider's structs" do
      n = %Glider.Node{id: 1, labels: ["Person"], props: %{"name" => "Ada", "born" => 1815.0}}
      e = %Glider.Rel{id: 2, type: "KNOWS", from: 1, to: 3, props: %{"since" => [1, 2]}}
      encoded = across(Wire.encode_value([n, e]))
      assert [%{"_e" => "node"}, %{"_e" => "rel"}] = encoded
      assert Wire.decode_value(encoded) == {:ok, [n, e]}
    end

    test "2: an object in a value's place without a tag, or with a wrong one, is refused" do
      for bad <- [
            %{"id" => 1},
            %{"_e" => "nope"},
            %{"_e" => "node", "id" => -1, "labels" => [], "props" => %{}},
            %{"_e" => "node", "id" => 1, "labels" => [1], "props" => %{}},
            %{"_e" => "node", "id" => 1, "labels" => [], "props" => %{}, "x" => 1},
            %{"_e" => "rel", "id" => 1, "type" => "T", "from" => 1, "props" => %{}}
          ] do
        assert {:error, reason} = Wire.decode_value(bad)
        assert is_binary(reason)
      end
    end

    test "2: a value nested past the limit is refused, not followed" do
      deep = Enum.reduce(1..100, 1, fn _, acc -> [acc] end)
      assert {:error, reason} = Wire.decode_value(deep)
      assert reason =~ "nested"
    end

    test "2: cards, schemas, stats, context and search answers come back as the local call gives them" do
      {:ok, card} = Card.new("a/b", description: "ünï", tags: ["x"], attrs: %{"owner" => "me"})
      card = %{card | nodes: 3, labels: [%{name: "L", count: 3}], store: "west"}

      assert Wire.decode_answer(:card, across(Wire.encode_answer(:card, card)), "west") ==
               {:ok, card}

      schema = %{
        labels: [%{name: "L", count: 3}],
        edge_types: [],
        indexes: [%{name: ":L(x)", count: 1}]
      }

      assert Wire.decode_answer(:schema, across(Wire.encode_answer(:schema, schema))) ==
               {:ok, schema}

      stats = %{"nodes" => 3, "edges" => 0, "ratio" => 1.0, "name" => "x"}
      assert Wire.decode_answer(:stats, across(Wire.encode_answer(:stats, stats))) == {:ok, stats}

      context = %{text: "n1:L x=1", tokens: 4, nodes: 1, edges: 0, refs: ["n1"], message: nil}

      assert Wire.decode_answer(:context, across(Wire.encode_answer(:context, context))) ==
               {:ok, context}

      hits = [%{ref: "a/b", score: 2.0, card: card}]

      assert Wire.decode_answer(:search, across(Wire.encode_answer(:search, hits)), "west") ==
               {:ok, hits}

      page = %{gliders: [card], next: "a/b"}

      assert Wire.decode_answer(:gliders, across(Wire.encode_answer(:gliders, page)), "west") ==
               {:ok, page}
    end

    test "2: nothing from the wire becomes an atom" do
      :rand.seed(:exsss, {2, 2, 26})

      novel = fn ->
        "never_an_atom_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
      end

      decode_all = fn key ->
        _ = Wire.decode_value(%{"_e" => key})
        _ = Wire.decode_value(%{"_e" => "map", "v" => %{key => key}})
        _ = Wire.decode_request(:context, %{"ref" => "a", key => 1})

        _ =
          Wire.decode_request(:query, %{"ref" => key, "cypher" => key, "params" => %{key => key}})

        _ = Wire.decode_error(%{"code" => key, "error" => key, "reason" => key})
        _ = Wire.decode_error(%{"code" => "unavailable", "error" => key, "reason" => key})
        _ = Wire.decode_answer(:stats, %{key => key})
        _ = Wire.decode_answer(:schema, %{key => []})
        _ = Wire.op(key)
      end

      # Once first, so what the decoders load on first use is not counted.
      decode_all.(novel.())
      before = :erlang.system_info(:atom_count)
      for _ <- 1..200, do: decode_all.(novel.())

      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "1: requests and errors" do
    test "1: every op's request crosses the wire and comes back as it was" do
      requests = [
        {:gliders, [after: "a", limit: 10, prefix: "x"]},
        {:card, "a/b"},
        {:create, "a/b",
         [description: "d", tags: ["t"], attrs: %{"owner" => "me"}, links: ["c"]]},
        {:update, "a/b", %{"description" => "new"}},
        {:delete, "a/b", [purge: true]},
        {:query, "a/b", "MATCH (n) RETURN n", %{"x" => 1.0},
         [graph: true, max_bytes: 9, max_rows: 3]},
        {:run, "a/b", "CREATE (:N)", %{}, [sync: :commit]},
        {:write_batch, "a/b", [{"CREATE (:N)", %{"a" => [1]}}], []},
        {:context, "a/b", [budget: 100, query: "ada"]},
        {:schema, "a/b"},
        {:stats, "a/b"},
        {:find, "MATCH (g:Glider) RETURN g.ref", %{}},
        {:search, "code", [top: 3]}
      ]

      for request <- requests do
        op = elem(request, 0)
        {:ok, segment, body} = Wire.encode_request(request)
        assert Wire.op(segment) == {:ok, op}
        {:ok, back} = Wire.decode_request(op, across(body))

        normal = fn r ->
          case r do
            {:create, ref, opts} -> {:create, ref, Enum.sort(opts)}
            {:gliders, opts} -> {:gliders, Enum.sort(opts)}
            {:query, ref, c, p, opts} -> {:query, ref, c, p, Enum.sort(opts)}
            other -> other
          end
        end

        assert normal.(back) == normal.(request)
      end
    end

    test "1: a body that is not a request of its op is refused with a message" do
      for {op, body} <- [
            {:query, %{"ref" => "a"}},
            {:query, %{"ref" => 1, "cypher" => "STATS"}},
            {:query, %{"ref" => "a", "cypher" => "STATS", "max_rows" => -1}},
            {:run, %{"ref" => "a", "cypher" => "X", "sync" => "never"}},
            {:write_batch, %{"ref" => "a", "statements" => [[1, 2]]}},
            {:context, %{"ref" => "a", "drop_tables" => true}},
            {:context, %{"ref" => "a", "format" => "json"}},
            {:create, %{"ref" => "a", "colour" => "blue"}},
            {:delete, %{"ref" => "a", "purge" => "yes"}},
            {:update, %{"ref" => "a"}}
          ] do
        assert {:error, message} = Wire.decode_request(op, body), inspect({op, body})
        assert is_binary(message)
      end

      assert {:error, _} = Wire.decode_request(:card, ["a"])
    end

    test "1: each reason has its code and status, and is read back as the same reason" do
      holder = %{
        holder: String.duplicate("a", 32),
        node: "n@h",
        url: "https://x/aerotow",
        flight: 7
      }

      for {reason, status, code} <- [
            {:not_found, 404, "not_found"},
            {:exists, 409, "exists"},
            {:purging, 409, "purging"},
            {{:aloft_elsewhere, holder}, 409, "aloft_elsewhere"},
            {{:runs_on_peer, "west"}, 409, "runs_on_peer"},
            {"MATCH ... SET is not a read", 422, "refused"},
            {:too_many_hops, 508, "too_many_hops"},
            {{:store_unavailable, "assets", "down"}, 503, "store_unavailable"},
            {{:peer_unavailable, "west", "down"}, 503, "peer_unavailable"},
            {{:outcome_unknown, "west", "lost"}, 503, "outcome_unknown"},
            {:not_running, 503, "unavailable"},
            {:lost, 503, "unavailable"},
            {:timeout, 504, "timeout"}
          ] do
        {^status, body} = Wire.encode_error(reason)
        assert %{"code" => ^code, "error" => message} = across(body)
        assert is_binary(message)
        {:ok, back} = Wire.decode_error(across(body))

        case reason do
          {kind, name, _} -> assert {^kind, ^name, _} = back
          _ -> assert back == reason
        end
      end

      assert {500, %{"code" => "error"}} = Wire.encode_error({:launch, :enospc})
      assert Wire.decode_error(%{"nope" => 1}) == :error
    end
  end
end
