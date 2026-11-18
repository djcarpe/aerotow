defmodule Aerotow.ObjectsCase do
  @moduledoc """
  What every object store holds (`Aerotow.Store.Objects`), written once and
  run against each kind: `Aerotow.Store.Dir` in a directory,
  `Aerotow.Store.S3` against its fake.

      defmodule Aerotow.Store.DirTest do
        use ExUnit.Case
        import Aerotow.ObjectsCase

        @moduletag :tmp_dir

        objects_conformance(fn %{tmp_dir: dir} ->
          {:ok, store} = Aerotow.Store.new("dir", Path.join(dir, "store"))
          store
        end)
      end

  The function is given the test's context and returns a fresh, empty store
  of an object kind, as `Aerotow.Store.new/3` makes it (so holding its
  marker, `aerotow.json`, and nothing else). Nothing here assumes a
  directory: every test goes through `Aerotow.Store` or through the store's
  own module and config. The test that replicates through glider keeps its
  database in the context's `:tmp_dir`, which it asks for.

  Option: `rounds:` (default 200), how many keys sixteen writers race for.
  The tests that race or replicate are given ten minutes: a put that syncs
  to disk is slow on a busy machine, and they are about what holds, not how
  fast.
  """

  @doc """
  Defines the conformance tests in the calling test module, in one
  `describe` block. `new_store` is a function of the test's context
  returning a fresh `%Aerotow.Store{}`.
  """
  defmacro objects_conformance(new_store, opts \\ []) do
    rounds = Keyword.get(opts, :rounds, 200)

    quote do
      describe "an object store" do
        setup context do
          %{store: unquote(new_store).(context)}
        end

        @tag timeout: 600_000
        test "R7: of sixteen exclusive puts racing for a key, exactly one wins, and the object is wholly its body",
             %{store: store} do
          for round <- 1..unquote(rounds) do
            key = "race/#{round}"
            test = self()
            go = make_ref()

            # A body of its own size and bytes for each writer, so that a
            # mixed or cut object shows.
            racers =
              for i <- 1..16 do
                body = String.duplicate(<<?a + i>>, i * 61 + rem(round, 7))

                pid =
                  spawn_link(fn ->
                    receive do
                      ^go ->
                        send(
                          test,
                          {go, self(), body, Aerotow.Store.put(store, key, body, exclusive: true)}
                        )
                    end
                  end)

                {pid, body}
              end

            Enum.each(racers, fn {pid, _} -> send(pid, go) end)

            results =
              for {pid, body} <- racers do
                assert_receive {^go, ^pid, ^body, result}, 30_000
                {body, result}
              end

            winners = for {body, :ok} <- results, do: body
            assert [winner] = winners, "round #{round}: #{length(winners)} exclusive puts won"

            assert Enum.count(results, &match?({_, {:error, :exists}}, &1)) == 15,
                   "round #{round}: #{inspect(Enum.map(results, &elem(&1, 1)))}"

            assert Aerotow.Store.get(store, key) == {:ok, winner}
          end
        end

        test "a plain put replaces what is there, and an exclusive put does not", %{store: store} do
          assert :ok = Aerotow.Store.put(store, "t/k", "one")
          assert {:error, :exists} = Aerotow.Store.put(store, "t/k", "two", exclusive: true)
          assert {:ok, "one"} = Aerotow.Store.get(store, "t/k")
          assert :ok = Aerotow.Store.put(store, "t/k", ["th", "ree"])
          assert {:ok, "three"} = Aerotow.Store.get(store, "t/k")
          assert :ok = Aerotow.Store.put(store, "t/fresh", "x", exclusive: true)
          assert {:ok, "x"} = Aerotow.Store.get(store, "t/fresh")
          assert :ok = Aerotow.Store.put(store, "t/empty", "")
          assert {:ok, ""} = Aerotow.Store.get(store, "t/empty")
          assert {:error, :not_found} = Aerotow.Store.get(store, "t/never")
        end

        @tag timeout: 600_000
        test "a reader never sees half an object, and never misses a key that is there throughout",
             %{store: store} do
          key = "t/rewritten"

          bodies =
            for {size, i} <- Enum.with_index([1, 3, 1_000, 65_537, 7, 20_000, 300]),
                do: String.duplicate(<<?a + i>>, size)

          whole = MapSet.new(bodies)
          :ok = Aerotow.Store.put(store, key, hd(bodies))
          test = self()

          reader = fn reader, reads ->
            receive do
              :stop -> send(test, {:reads, self(), reads})
            after
              0 ->
                case Aerotow.Store.get(store, key) do
                  {:ok, body} ->
                    if MapSet.member?(whole, body),
                      do: reader.(reader, reads + 1),
                      else: send(test, {:read, self(), {:partial, byte_size(body)}})

                  other ->
                    send(test, {:read, self(), other})
                end
            end
          end

          readers = for _ <- 1..4, do: spawn_link(fn -> reader.(reader, 0) end)

          for _ <- 1..12, body <- Enum.shuffle(bodies) do
            assert :ok = Aerotow.Store.put(store, key, body)
          end

          Enum.each(readers, &send(&1, :stop))

          for pid <- readers do
            assert_receive {:reads, ^pid, reads}, 30_000
            assert reads > 0
          end

          refute_received {:read, _, _}
        end

        test "a listing comes back in key order", %{store: store} do
          keys =
            ~w(t/b t/a.json t/a/b.json t/a-b/c t/a0 t/a/a t/a/b t/ab t/a.b/c t/z/y/x/w t/~ t/a/b.c t/a_)

          for key <- Enum.shuffle(keys), do: :ok = Aerotow.Store.put(store, key, key)

          assert {:ok, %{objects: objects, prefixes: []}} = Aerotow.Store.list(store, "t/")
          assert Enum.map(objects, & &1.key) == Enum.sort(keys)
          assert Enum.all?(objects, &(&1.size == byte_size(&1.key)))

          assert {:ok, %{objects: all}} = Aerotow.Store.list(store, "")
          assert Enum.map(all, & &1.key) == Enum.sort(["aerotow.json" | keys])
        end

        test "with a delimiter, a listing is what is directly under the prefix, and the directories below it as prefixes",
             %{store: store} do
          for key <- ~w(t/x/1 t/x/2 t/x/d/3 t/x/d/e/4 t/x/f/5 t/x/g.json t/y/1 t/xa/1),
              do: :ok = Aerotow.Store.put(store, key, key)

          assert {:ok, %{objects: objects, prefixes: ["t/x/d/", "t/x/f/"]}} =
                   Aerotow.Store.list(store, "t/x/", delimiter: true)

          assert Enum.map(objects, & &1.key) == ~w(t/x/1 t/x/2 t/x/g.json)

          assert {:ok, %{objects: [], prefixes: ["t/x/", "t/xa/"]}} =
                   Aerotow.Store.list(store, "t/x", delimiter: true)

          assert {:ok, %{objects: [], prefixes: ["t/x/d/"]}} =
                   Aerotow.Store.list(store, "t/x/d", delimiter: true)

          assert {:ok, %{objects: [%{key: "t/x/g.json"}], prefixes: []}} =
                   Aerotow.Store.list(store, "t/x/g", delimiter: true)

          assert {:ok, %{objects: [%{key: "aerotow.json"}], prefixes: ["t/"]}} =
                   Aerotow.Store.list(store, "", delimiter: true)

          assert {:ok, %{objects: everything, prefixes: []}} = Aerotow.Store.list(store, "t/x/")

          assert Enum.map(everything, & &1.key) ==
                   ~w(t/x/1 t/x/2 t/x/d/3 t/x/d/e/4 t/x/f/5 t/x/g.json)
        end

        test "a delimiter listing of a glider's flights is its records and their directories, and nothing inside them",
             %{store: store} do
          ref = "eng/code"
          data = Aerotow.Store.Layout.flight_data(ref, 1)
          generation = "96348bfb24205901aabbccddeeff0011"

          :ok = Aerotow.Store.put(store, Aerotow.Store.Layout.flight_record(ref, 1), "{}")
          :ok = Aerotow.Store.put(store, Aerotow.Store.Layout.flight_record(ref, 2), "{}")

          :ok =
            Aerotow.Store.put(store, "#{data}/#{generation}/base/0000000000000000/db", "pages")

          :ok =
            Aerotow.Store.put(
              store,
              "#{data}/#{generation}/base/0000000000000000/base.json",
              "{}"
            )

          for i <- 1..40 do
            offset = i |> Integer.to_string(16) |> String.pad_leading(16, "0")

            :ok =
              Aerotow.Store.put(
                store,
                "#{data}/#{generation}/segments/#{offset}-1763400000.seg",
                "log"
              )
          end

          # The glider eng/code/v2 is kept under eng/code's own directory.
          :ok =
            Aerotow.Store.put(store, Aerotow.Store.Layout.flight_record("eng/code/v2", 1), "{}")

          assert {:ok, %{objects: objects, prefixes: prefixes}} =
                   Aerotow.Store.list(store, Aerotow.Store.Layout.flights_prefix(ref),
                     delimiter: true
                   )

          assert Enum.map(objects, & &1.key) == [
                   Aerotow.Store.Layout.flight_record(ref, 1),
                   Aerotow.Store.Layout.flight_record(ref, 2)
                 ]

          assert prefixes == [data <> "/"]
        end

        test "a prefix that matches nothing is an empty listing", %{store: store} do
          :ok = Aerotow.Store.put(store, "t/k", "x")

          for prefix <- ["nothing/", "nothing/at/all/", "t/k/", "t/q", "t/k/deeper/", "u"],
              delimiter <- [true, false] do
            assert Aerotow.Store.list(store, prefix, delimiter: delimiter) ==
                     {:ok, %{objects: [], prefixes: []}},
                   "#{prefix}, delimiter: #{delimiter}"
          end
        end

        test "what a put writes on the way is never listed and never read", %{store: store} do
          {:ok, %{objects: before}} = Aerotow.Store.list(store, "")
          bodies = for i <- 1..12, into: %{}, do: {"t/w/#{i}", String.duplicate("w", 4_000 + i)}
          allowed = MapSet.new(Enum.map(before, & &1.key) ++ Map.keys(bodies))

          writer =
            Task.async(fn ->
              for _ <- 1..3, {key, body} <- bodies, do: :ok = Aerotow.Store.put(store, key, body)
            end)

          check = fn check, listings ->
            {:ok, %{objects: objects}} = Aerotow.Store.list(store, "")

            for %{key: key} <- objects do
              assert MapSet.member?(allowed, key), "listed #{inspect(key)}"

              if Map.has_key?(bodies, key),
                do: assert(Aerotow.Store.get(store, key) == {:ok, bodies[key]})
            end

            if Task.yield(writer, 0), do: listings, else: check.(check, listings + 1)
          end

          assert check.(check, 1) > 0
          {:ok, %{objects: after_writing}} = Aerotow.Store.list(store, "")
          assert MapSet.new(after_writing, & &1.key) == allowed
        end

        test "an object's version changes when its content does, and not otherwise", %{
          store: store
        } do
          :ok = Aerotow.Store.put(store, "t/a", "1111")
          :ok = Aerotow.Store.put(store, "t/b", "kept")

          versions = fn ->
            {:ok, %{objects: objects}} = Aerotow.Store.list(store, "t/")
            Map.new(objects, &{&1.key, &1.version})
          end

          first = versions.()
          assert is_binary(first["t/a"])
          assert versions.() == first

          # Rewritten at once, at the same size: a new version each time, never
          # one seen before, and the other object's stays as it was.
          seen =
            Enum.reduce(~w(2222 3333 4444 5555 6666), [first["t/a"]], fn body, seen ->
              :ok = Aerotow.Store.put(store, "t/a", body)
              now = versions.()
              refute now["t/a"] in seen
              assert now["t/b"] == first["t/b"]
              [now["t/a"] | seen]
            end)

          assert versions.()["t/a"] == hd(seen)
          assert versions.()["t/b"] == first["t/b"]
        end

        test "a key or prefix that could leave the store is refused by every operation, and nothing is written",
             %{store: store} do
          {:ok, before} = Aerotow.Store.list(store, "")

          bad_keys = [
            "",
            "/",
            "/a",
            "a//b",
            "a/",
            ".",
            "..",
            "./a",
            "a/.",
            "a/./b",
            "a/../b",
            "../a",
            "a/..",
            "a\\b",
            "..\\a",
            "a\0b",
            "a\nb",
            <<"a", 255>>,
            String.duplicate("a/", 600) <> "a",
            nil,
            :a,
            ~c"a/b",
            12
          ]

          for key <- bad_keys do
            results = [
              Aerotow.Store.get(store, key),
              Aerotow.Store.put(store, key, "x"),
              Aerotow.Store.put(store, key, "x", exclusive: true),
              Aerotow.Store.delete(store, key),
              Aerotow.Store.replica(store, key),
              store.mod.get(store.config, key),
              store.mod.put(store.config, key, "x", []),
              store.mod.put(store.config, key, "x", exclusive: true),
              store.mod.delete(store.config, key)
            ]

            for result <- results do
              assert {:error, reason} = result
              assert is_binary(reason), "#{inspect(key)} gave #{inspect(result)}"
            end
          end

          bad_prefixes = [
            "/",
            "/a",
            "a//",
            "..",
            "../",
            "a/../",
            "a/..",
            "./",
            "a\\",
            "a\0",
            <<255>>,
            nil
          ]

          for prefix <- bad_prefixes, delimiter <- [true, false] do
            for result <- [
                  Aerotow.Store.list(store, prefix, delimiter: delimiter),
                  store.mod.list(store.config, prefix, delimiter: delimiter)
                ] do
              assert {:error, reason} = result
              assert is_binary(reason), "#{inspect(prefix)} gave #{inspect(result)}"
            end
          end

          assert Aerotow.Store.list(store, "") == {:ok, before}
        end

        test "deleting a key that is not there is :ok, and a deleted key is gone from get and list",
             %{store: store} do
          assert :ok = Aerotow.Store.delete(store, "t/never")
          :ok = Aerotow.Store.put(store, "t/d/1", "x")
          :ok = Aerotow.Store.put(store, "t/d/2", "y")
          :ok = Aerotow.Store.put(store, "t/e", "z")

          assert :ok = Aerotow.Store.delete(store, "t/d/1")
          assert {:error, :not_found} = Aerotow.Store.get(store, "t/d/1")
          assert {:ok, %{objects: objects}} = Aerotow.Store.list(store, "t/")
          assert Enum.map(objects, & &1.key) == ~w(t/d/2 t/e)
          assert :ok = Aerotow.Store.delete(store, "t/d/1")

          # With the last object under it gone, a prefix is gone from listings.
          assert :ok = Aerotow.Store.delete(store, "t/d/2")

          assert {:ok, %{objects: [%{key: "t/e"}], prefixes: []}} =
                   Aerotow.Store.list(store, "t/", delimiter: true)

          assert :ok = Aerotow.Store.delete(store, "t/e")

          assert {:ok, %{objects: [], prefixes: []}} =
                   Aerotow.Store.list(store, "t/", delimiter: true)

          assert {:ok, %{prefixes: []}} = Aerotow.Store.list(store, "", delimiter: true)
        end

        @tag :tmp_dir
        @tag timeout: 600_000
        test "glider replicates into replica/2 and restores from it, and the flight's directory is all a listing shows",
             %{store: store, tmp_dir: dir} do
          ref = "eng/code"
          path = Path.join(dir, "work.gldb")
          {:ok, db} = Glider.open(path)

          {:ok, _} =
            Glider.run(db, ~S|CREATE (:Job {name:"build"})-[:BLOCKS]->(:Job {name:"test"})|)

          {url, opts} = Aerotow.Store.replica(store, Aerotow.Store.Layout.flight_data(ref, 1))
          sync_opts = [db: db, spool: Path.join(dir, "spool")] ++ opts

          # An idle handle can wait for ever for its base (an engine bug), so
          # a sync that hangs fails the test instead of stalling the suite.
          sync = fn ->
            task = Task.async(fn -> Glider.Replication.sync(path, url, sync_opts) end)
            Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill)
          end

          assert {:ok, {:ok, %{bases_uploaded: 1}}} = sync.()
          {:ok, _} = Glider.run(db, ~S|CREATE (:Job {name:"deploy"})|)
          assert {:ok, {:ok, %{segments_uploaded: segments}}} = sync.()
          assert segments > 0

          names = fn db ->
            {:ok, %{rows: rows}} = Glider.query(db, "MATCH (j:Job) RETURN j.name ORDER BY j.name")
            rows
          end

          out = Path.join(dir, "restored.gldb")
          assert {:ok, _} = Glider.Replication.restore(url, out, opts)
          {:ok, back} = Glider.open(out)
          assert names.(back) == names.(db)
          assert length(names.(back)) == 3
          Glider.close(back)
          Glider.close(db)

          prefix = Aerotow.Store.Layout.flight_data(ref, 1) <> "/"

          assert {:ok, %{objects: [], prefixes: [^prefix]}} =
                   Aerotow.Store.list(store, Aerotow.Store.Layout.flights_prefix(ref),
                     delimiter: true
                   )

          assert {:ok, %{objects: shipped}} = Aerotow.Store.list(store, prefix)
          assert Enum.any?(shipped, &String.ends_with?(&1.key, "/base.json"))
          assert Enum.all?(shipped, &String.starts_with?(&1.key, prefix))
        end

        test "probe/1 finds exclusive puts exclusive by racing them, and leaves nothing behind",
             %{store: store} do
          assert store.cas == true
          assert store.id =~ ~r/\A[0-9a-f]{32}\z/
          {:ok, before} = Aerotow.Store.list(store, "")
          assert {:ok, %{cas: true}} = store.mod.probe(store.config)
          assert Aerotow.Store.list(store, "") == {:ok, before}
        end

        test "the gliders a and a/b are independent: their cards, their listings, a purge of either",
             %{store: store} do
          for ref <- ["a", "a/b"] do
            {:ok, card} = Aerotow.Card.new(ref, description: "the glider #{ref}")
            :ok = Aerotow.Store.write_card(store, card)

            :ok =
              Aerotow.Store.put(
                store,
                Aerotow.Store.Layout.flight_record(ref, 1),
                ~s|{"ref": "#{ref}"}|
              )

            data = Aerotow.Store.Layout.flight_data(ref, 1)

            :ok =
              Aerotow.Store.put(store, data <> "/0123456789abcdef0123456789abcdef/base/0/db", ref)
          end

          assert {:ok, [%{ref: "a"}, %{ref: "a/b"}]} = Aerotow.Store.list_cards(store)
          {:ok, %{objects: [_, _] = flights_of_ab}} = Aerotow.Store.list(store, "gliders/a/b/")

          assert :ok = Aerotow.Store.purge(store, "a")
          assert {:error, :not_found} = Aerotow.Store.read_card(store, "a")
          assert {:ok, %Aerotow.Card{ref: "a/b"}} = Aerotow.Store.read_card(store, "a/b")
          assert {:ok, [%{ref: "a/b"}]} = Aerotow.Store.list_cards(store)

          assert {:ok, %{objects: [], prefixes: []}} =
                   Aerotow.Store.list(store, Aerotow.Store.Layout.flights_prefix("a"))

          assert {:ok, %{objects: ^flights_of_ab}} = Aerotow.Store.list(store, "gliders/a/b/")

          assert :ok = Aerotow.Store.purge(store, "a/b")
          assert {:ok, []} = Aerotow.Store.list_cards(store)
          assert {:ok, %{objects: [], prefixes: []}} = Aerotow.Store.list(store, "gliders/")
          assert {:ok, %{objects: [], prefixes: []}} = Aerotow.Store.list(store, "cards/")
        end
      end
    end
  end
end
