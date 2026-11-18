defmodule Aerotow.PlugTest do
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import Aerotow.PeerCase
  import ExUnit.CaptureLog

  alias Aerotow.{Instance, Wire}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "served/graph"

  setup %{tmp_dir: dir} do
    tow =
      tow(Path.join(dir, "tow"),
        stores: [{"store", Path.join(dir, "store")}],
        default_store: "store"
      )

    {:ok, _} = Aerotow.create(tow, @ref)

    {:ok, 5} =
      Aerotow.write_batch(tow, @ref, for(i <- 1..5, do: {"CREATE (:N {i: $i})", %{i: i}}))

    %{tow: tow}
  end

  defp request(method, url, opts) do
    {token, opts} = Keyword.pop(opts, :token, token())
    {body, opts} = Keyword.pop(opts, :body, nil)
    {headers, _} = Keyword.pop(opts, :headers, [])

    auth = if token, do: [{"authorization", "Bearer " <> token}], else: []

    body =
      cond do
        is_nil(body) -> ""
        is_binary(body) -> body
        true -> JSON.encode!(body)
      end

    {:ok, resp} =
      Req.request(
        method: method,
        url: url,
        headers: auth ++ headers,
        body: body,
        retry: false,
        decode_body: false
      )

    json =
      case JSON.decode(resp.body) do
        {:ok, json} -> json
        _ -> resp.body
      end

    {resp.status, json, resp}
  end

  defp post(url, op, body, opts \\ []),
    do: request(:post, url <> "/v1/" <> op, Keyword.put(opts, :body, body))

  defp count(tow) do
    {:ok, %{rows: [[n]]}} = Aerotow.query(tow, @ref, "MATCH (n) RETURN count(n)")
    n
  end

  describe "1: the protocol" do
    test "1: GET /v1 answers the aerotow's id and format; every answer carries the id", %{
      tow: tow
    } do
      url = serve(tow)
      id = Instance.fetch!(tow).id
      {200, body, resp} = request(:get, url <> "/v1", [])
      assert %{"id" => ^id, "format" => 1, "aerotow" => version} = body
      assert is_binary(version)
      assert Req.Response.get_header(resp, "aerotow-id") == [id]

      {404, _, resp} = post(url, "card", %{"ref" => "no/such"})
      assert Req.Response.get_header(resp, "aerotow-id") == [id]
    end

    test "1: every op is POST /v1/<op> with a JSON body", %{tow: tow} do
      url = serve(tow)

      assert {200, %{"columns" => ["count(n)"], "rows" => [[5]]}, _} =
               post(url, "query", %{"ref" => @ref, "cypher" => "MATCH (n) RETURN count(n)"})

      assert {200, %{"touched" => 1}, _} =
               post(url, "run", %{
                 "ref" => @ref,
                 "cypher" => "CREATE (:N {i: $i})",
                 "params" => %{"i" => 6}
               })

      assert {200, %{"touched" => 2}, _} =
               post(url, "batch", %{
                 "ref" => @ref,
                 "statements" => [
                   ["CREATE (:N {i: 7})", %{}],
                   ["CREATE (:N {i: $i})", %{"i" => 8}]
                 ]
               })

      assert {200, %{"ref" => @ref, "format" => 1}, _} = post(url, "card", %{"ref" => @ref})

      assert {200, %{"labels" => [%{"name" => "N", "count" => 8}]}, _} =
               post(url, "schema", %{"ref" => @ref})

      assert {200, %{"nodes" => 8}, _} = post(url, "stats", %{"ref" => @ref})

      assert {200, %{"gliders" => [%{"ref" => @ref}], "next" => nil}, _} =
               post(url, "gliders", %{})

      assert {200, %{"rows" => [[@ref]]}, _} =
               post(url, "find", %{"cypher" => "MATCH (g:Glider) RETURN g.ref"})

      assert {200, [], _} = post(url, "search", %{"query" => "nothing-like-it"})

      assert {200, %{"ref" => "served/new"}, _} =
               post(url, "create", %{"ref" => "served/new", "tags" => ["t"], "store" => "store"})

      assert {200, %{"description" => "d"}, _} =
               post(url, "update", %{"ref" => "served/new", "changes" => %{"description" => "d"}})

      assert {200, %{}, _} = post(url, "delete", %{"ref" => "served/new", "purge" => true})
      assert {404, %{"code" => "not_found"}, _} = post(url, "card", %{"ref" => "served/new"})

      assert {422, %{"code" => "refused"}, _} =
               post(url, "context", %{"ref" => @ref, "query" => "x"})
    end

    test "1: unknown ops, wrong methods, bodies that are not JSON objects and bodies over the limit are refused before anything runs",
         %{tow: tow} do
      url = serve(tow, max_body: 200)
      run = %{"ref" => @ref, "cypher" => "CREATE (:N {i: 99})"}

      for name <- Wire.names() do
        assert {405, %{"code" => "method_not_allowed"}, _} =
                 request(:get, url <> "/v1/" <> name, [])
      end

      assert {404, %{"code" => "unknown_op"}, _} = post(url, "drop", run)
      assert {404, %{"code" => "unknown_op"}, _} = request(:post, url <> "/v2/run", body: run)
      assert {405, %{"code" => "method_not_allowed"}, _} = request(:post, url <> "/v1", body: run)

      assert {405, %{"code" => "method_not_allowed"}, _} =
               request(:put, url <> "/v1/run", body: run)

      assert {400, %{"code" => "bad_request"}, _} = post(url, "run", "[1]")
      assert {400, %{"code" => "bad_request"}, _} = post(url, "run", "CREATE (:N)")
      assert {400, %{"code" => "bad_request"}, _} = post(url, "run", %{"ref" => @ref})

      assert {400, %{"code" => "bad_request"}, _} =
               post(url, "run", run, headers: [{"aerotow-hops", "lots"}])

      big = Map.put(run, "params", %{"pad" => String.duplicate("x", 300)})
      assert {413, %{"code" => "too_large"}, _} = post(url, "run", big)

      # Streamed with no length given, the same.
      {:ok, resp} =
        Req.post(url <> "/v1/run",
          headers: [{"authorization", "Bearer " <> token()}],
          body: Stream.map([JSON.encode!(big)], & &1),
          retry: false
        )

      assert resp.status == 413
      assert count(tow) == 5
    end

    test "1: errors carry a code and a matching status", %{tow: tow} do
      url = serve(tow)

      assert {404, %{"code" => "not_found", "error" => _}, _} =
               post(url, "query", %{"ref" => "no/such", "cypher" => "STATS"})

      assert {400, %{"code" => "bad_request"}, _} =
               post(url, "query", %{"ref" => "Not A Ref", "cypher" => 1})

      assert {422, %{"code" => "refused", "error" => error}, _} =
               post(url, "query", %{"ref" => "Not A Ref", "cypher" => "STATS"})

      assert error =~ "not a ref"

      assert {409, %{"code" => "exists"}, _} =
               post(url, "create", %{"ref" => @ref})

      assert {508, %{"code" => "too_many_hops"}, _} =
               post(url, "query", %{"ref" => @ref, "cypher" => "STATS"},
                 headers: [{"aerotow-hops", "4"}]
               )
    end
  end

  describe "6: the receiving side applies its own rules" do
    test "6: a query that writes is refused, naming run/5, and writes nothing", %{tow: tow} do
      url = serve(tow)

      assert {422, %{"code" => "refused", "error" => error}, _} =
               post(url, "query", %{"ref" => @ref, "cypher" => "MATCH (n) SET n.x = 1 RETURN n"})

      assert error =~ "run/5"

      assert {422, _, _} =
               post(url, "query", %{
                 "ref" => @ref,
                 "cypher" => "MATCH (n) WHERE n.i = 1 DETACH DELETE n"
               })

      assert count(tow) == 5
    end

    test "6: run and batch refuse BEGIN, COMMIT and ROLLBACK", %{tow: tow} do
      url = serve(tow)

      for statement <- ["BEGIN", " // a comment\n commit", "`ROLLBACK`", "EXPLAIN BEGIN"] do
        assert {422, %{"error" => error}, _} =
                 post(url, "run", %{"ref" => @ref, "cypher" => statement})

        assert error =~ "checkout"

        assert {422, _, _} =
                 post(url, "batch", %{
                   "ref" => @ref,
                   "statements" => [["CREATE (:N)", %{}], [statement, %{}]]
                 })
      end

      # The handle still commits on its own: a write is seen at once.
      assert {200, %{"touched" => 1}, _} =
               post(url, "run", %{"ref" => @ref, "cypher" => "CREATE (:N)"})

      assert count(tow) == 6
    end

    test "6: the receiver's max_rows and max_bytes bound what it answers, whatever is asked", %{
      tow: tow
    } do
      url = serve(tow, max_rows: 2, max_bytes: 100_000)
      all = %{"ref" => @ref, "cypher" => "MATCH (n) RETURN n.i", "max_rows" => 1_000}
      assert {422, %{"code" => "refused"}, _} = post(url, "query", all)

      assert {200, %{"rows" => [_, _]}, _} =
               post(url, "query", %{all | "cypher" => "MATCH (n) RETURN n.i LIMIT 2"})

      url = serve(tow, max_bytes: 64)

      assert {422, _, _} =
               post(url, "query", %{
                 "ref" => @ref,
                 "cypher" => "MATCH (n) RETURN $pad",
                 "params" => %{"pad" => String.duplicate("x", 200)},
                 "max_bytes" => 10_000_000
               })
    end
  end

  describe "7: authorization" do
    test "7: a request without a valid token is refused before its body is decoded", %{tow: tow} do
      url = serve(tow, tokens: ["first-token", token()], max_body: 100)
      run = %{"ref" => @ref, "cypher" => "CREATE (:N)"}

      {401, %{"code" => "unauthorized"}, resp} = post(url, "run", run, token: nil)
      assert Req.Response.get_header(resp, "www-authenticate") == ["Bearer"]
      assert {401, _, _} = post(url, "run", run, token: "wrong")
      assert {401, _, _} = post(url, "run", run, token: token() <> "x")
      assert {401, _, _} = request(:get, url <> "/v1", token: nil)
      # Not read: a body that is not JSON, or too large, is not what is wrong.
      assert {401, _, _} = post(url, "run", "not json", token: nil)
      assert {401, _, _} = post(url, "run", String.duplicate("x", 1_000), token: nil)
      assert count(tow) == 5

      assert {200, _, _} = post(url, "run", run, token: "first-token")
      assert {200, _, _} = post(url, "run", run)
      assert count(tow) == 7
    end

    test "7: authorize: is given the conn and the op and ref, and its refusal is the answer", %{
      tow: tow
    } do
      test = self()

      authorize = fn conn, %{op: op, ref: ref} ->
        send(test, {:asked, op, ref, conn.method})

        case ref do
          "secret/" <> _ -> {:error, 403, "not yours"}
          "teapot" -> {:error, 418, "short and stout"}
          _ -> :ok
        end
      end

      url = serve(tow, tokens: nil, authorize: authorize)

      assert {200, _, _} = post(url, "query", %{"ref" => @ref, "cypher" => "STATS"}, token: nil)
      assert_receive {:asked, :query, @ref, "POST"}

      assert {403, %{"code" => "forbidden", "error" => "not yours"}, _} =
               post(url, "run", %{"ref" => "secret/x", "cypher" => "CREATE (:N)"}, token: nil)

      assert_receive {:asked, :run, "secret/x", "POST"}
      assert {418, _, _} = post(url, "card", %{"ref" => "teapot"}, token: nil)
      assert {200, _, _} = request(:get, url <> "/v1", token: nil)
      assert_receive {:asked, :info, nil, "GET"}
      assert {200, _, _} = post(url, "gliders", %{}, token: nil)
      assert_receive {:asked, :gliders, nil, "POST"}
    end

    test "7: with neither tokens: nor authorize: the plug refuses to start" do
      assert_raise ArgumentError, ~r/tokens: or authorize:/, fn -> Aerotow.Plug.init(tow: :x) end
      assert_raise ArgumentError, fn -> Aerotow.Plug.init(tow: :x, tokens: []) end
      assert_raise ArgumentError, fn -> Aerotow.Plug.init(tow: :x, tokens: [""]) end
      assert_raise ArgumentError, fn -> Aerotow.Plug.init(tokens: ["t"]) end
      refute inspect(Aerotow.Plug.init(tow: :x, tokens: ["hidden-#{token()}"])) =~ "hidden-"
    end

    test "7: the token is in no reason, log line or telemetry event", %{tow: tow, tmp_dir: dir} do
      listen([
        [:aerotow, :plug, :start],
        [:aerotow, :plug, :stop],
        [:aerotow, :forward, :start],
        [:aerotow, :forward, :stop],
        [:aerotow, :statement, :stop],
        [:aerotow, :scan, :stop]
      ])

      url = serve(tow)

      log =
        capture_log(fn ->
          here =
            tow(Path.join(dir, "here"),
              stores: [{"peer", url, token: token()}, {"wrong", url, token: "wrong-" <> token()}]
            )

          {:ok, _} = Aerotow.scan(here, "peer")
          {:ok, _} = Aerotow.query(here, @ref, "STATS")
          {:error, _} = Aerotow.query(here, @ref, "MATCH (n) RETURN nothing(")
          {:ok, stores} = Aerotow.stores(here)
          refute inspect(stores) =~ token()
          {:error, reason} = Aerotow.Store.new("x", url, token: "wrong-" <> token())
          refute reason =~ token()

          _ =
            post(url, "run", %{"ref" => @ref, "cypher" => "CREATE (:N)"},
              token: "wrong-" <> token()
            )

          Logger.flush()
        end)

      refute log =~ token()
      events = collect_events([])
      assert Enum.any?(events, &match?({[:aerotow, :plug, :stop], _, _}, &1))
      assert Enum.any?(events, &match?({[:aerotow, :forward, :stop], _, _}, &1))
      refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ token()
    end
  end

  describe "9: telemetry" do
    test "9: each request is a span with its op, ref and status", %{tow: tow} do
      listen([[:aerotow, :plug, :start], [:aerotow, :plug, :stop]])
      url = serve(tow)
      post(url, "query", %{"ref" => @ref, "cypher" => "STATS"})
      post(url, "nope", %{})

      assert_receive {:telemetry, [:aerotow, :plug, :start], _, %{op: "query", method: "POST"}}

      assert_receive {:telemetry, [:aerotow, :plug, :stop], %{duration: _},
                      %{op: "query", ref: @ref, status: 200}}

      assert_receive {:telemetry, [:aerotow, :plug, :stop], _,
                      %{op: "nope", ref: nil, status: 404}}
    end
  end

  defp collect_events(acc) do
    receive do
      {:telemetry, event, measurements, meta} ->
        collect_events([{event, measurements, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
