defmodule Aerotow.CatalogTest do
  # Not async: Aerotow.CardTest counts the VM's atoms around its own run,
  # and these tests load modules and name a catalog while they run.
  use ExUnit.Case, async: false

  alias Aerotow.{Card, Catalog}

  @moduletag :tmp_dir

  @int_max 9_223_372_036_854_775_807
  @int_min -9_223_372_036_854_775_808

  # Text that would change a statement it was spliced into.
  @hostile [
    ~S|a"b|,
    ~S|a'b|,
    ~S|a\b|,
    ~S|a}b{c|,
    ~S|"}) DETACH DELETE (n) //|,
    ~S|$ref|,
    ~S|`tick`|,
    "line\nbreak",
    ~S|\"|
  ]

  @texts [
    "the code graph",
    "naïve café, crème brûlée",
    "日本語のグラフ",
    "emoji 🚀 and ✨",
    ~S|a "quoted" word, it's|,
    ~S|back\slash and \n that is not a newline|,
    "} closing { opening",
    "$ref and $1",
    "line one\nline two\ttabbed",
    "nul \u0000 inside",
    ""
  ]

  @labels [
    "CodeEntity",
    "Person",
    "Section",
    "Über",
    "Code Entity",
    ~S|Quo"te|,
    ~S|Back\slash|,
    "Brace}"
  ]
  @types ["CALLS", "KNOWS", "HAS_PART", ~S|ODD"TYPE|, "Ünï"]
  @indexes [":CodeEntity(path)", ":Person(name)", ~S|:Odd("x")|]
  @tags ~w(code docs big small x.y a_b c-d e:f 0day)
  @attr_names ~w(visibility owner org priority ratio live owners note)
  @attr_values [
    "public",
    "",
    ~S|"}) DETACH DELETE (n) //|,
    "ünïcödé 🚀",
    0,
    -1,
    42,
    @int_max,
    @int_min,
    0.5,
    -1.25e10,
    1.0,
    true,
    false,
    [],
    ["a", "b"],
    ["ü", ~S|"|]
  ]

  setup %{tmp_dir: dir} do
    cat = start_catalog(dir)
    Enum.each(stores(), &(:ok = Catalog.put_store(cat, &1)))
    %{cat: cat, dir: dir}
  end

  describe "a card comes back as it went in" do
    test "generated cards, empty, full and in between, come back exactly", %{cat: cat} do
      refs = for i <- 1..150, do: "team-#{rem(i, 7)}/glider.#{i}"
      pool = Enum.take(refs, 25) ++ ["outside/one", "outside/two"]

      cards = [
        card("solo/empty"),
        full_card("solo/full") | Enum.map(refs, &random_card(&1, pool))
      ]

      for card <- cards do
        assert :ok = Catalog.put_card(cat, card)
        assert {:ok, back} = Catalog.card(cat, card.ref)
        assert back === card
      end

      # The same cards again, through put_cards.
      again = Enum.map(refs, &random_card(&1, pool))
      assert :ok = Catalog.put_cards(cat, again)

      for card <- again do
        assert {:ok, back} = Catalog.card(cat, card.ref)
        assert back === card
      end
    end

    test "putting a card the catalog already has changes nothing in the file", %{cat: cat} do
      pool = ["other/one", "keep/a"]
      cards = [full_card("keep/full") | for(i <- 1..30, do: random_card("keep/c#{i}", pool))]
      assert :ok = Catalog.put_cards(cat, cards)
      before = export(cat)

      for card <- cards, do: assert(:ok = Catalog.put_card(cat, card))
      assert :ok = Catalog.put_cards(cat, cards)

      assert export(cat) == before
    end

    test "after many changes and deletes the catalog is what a fresh one given only the last cards is",
         %{cat: cat, dir: dir} do
      fresh = start_catalog(dir, file: "fresh.gldb")
      Enum.each(stores(), &(:ok = Catalog.put_store(fresh, &1)))
      pool = for i <- 1..10, do: "pool/g#{i}"
      links = pool ++ ["outside/a", "outside/b", "outside/c"]

      last =
        Enum.reduce(1..120, %{}, fn _, last ->
          ref = Enum.random(pool)

          if :rand.uniform(6) == 1 do
            assert :ok = Catalog.delete_card(cat, ref)
            Map.delete(last, ref)
          else
            card = random_card(ref, links)
            assert :ok = Catalog.put_card(cat, card)
            Map.put(last, ref, card)
          end
        end)

      assert :ok = Catalog.put_cards(fresh, Map.values(last))
      assert dump(cat) == dump(fresh)

      for {ref, card} <- last do
        assert {:ok, back} = Catalog.card(cat, ref)
        assert back === card
      end
    end

    test "a removed attr, tag, label, type or link is gone from the node and its edges",
         %{cat: cat} do
      old =
        card("eng/code",
          tags: ["code", "old-tag"],
          attrs: %{"visibility" => "public", "owner" => "dj"},
          links: ["eng/docs"],
          labels: [%{name: "CodeEntity", count: 3}, %{name: "Gone", count: 1}],
          types: [%{name: "CALLS", count: 2}]
        )

      new =
        card("eng/code",
          tags: ["code"],
          attrs: %{"visibility" => "public"},
          labels: [%{name: "CodeEntity", count: 4}]
        )

      assert :ok = Catalog.put_card(cat, old)
      assert :ok = Catalog.put_card(cat, new)
      assert {:ok, back} = Catalog.card(cat, "eng/code")
      assert back === new

      [[keys]] = rows(cat, "MATCH (g:Glider {ref: $r}) RETURN keys(g)", r: "eng/code")
      refute "owner" in keys
      assert "visibility" in keys

      edges =
        rows(
          cat,
          "MATCH (g:Glider {ref: $r})-[e]->(x) RETURN type(e), coalesce(x.name, x.ref), e.count",
          r: "eng/code"
        )

      assert Enum.sort(edges) == [
               ["HAS_LABEL", "CodeEntity", 4],
               ["HOMED_IN", "assets", nil],
               ["TAGGED", "code", nil]
             ]

      assert rows(cat, "MATCH (t:Tag) RETURN t.name") == [["code"]]
      assert rows(cat, "MATCH (l:Label) RETURN l.name") == [["CodeEntity"]]
      assert rows(cat, "MATCH (t:EdgeType) RETURN t.name") == []
      # Nothing links to eng/docs any more, so its stub is gone too.
      assert rows(cat, "MATCH (g:Glider {ref: $r}) RETURN g.known", r: "eng/docs") == []
    end

    test "a card too large for one write slice is written, replaced and deleted whole",
         %{dir: dir} do
      small = start_catalog(dir, file: "small.gldb", slice_bytes: 65_536)
      wide = start_catalog(dir, file: "wide.gldb")
      both = [small, wide]
      for c <- both, s <- stores(), do: :ok = Catalog.put_store(c, s)

      big = big_card("big/one", 150)
      for c <- both, do: assert(:ok = Catalog.put_card(c, big))
      assert {:ok, back} = Catalog.card(small, "big/one")
      assert back === big
      assert dump(small) == dump(wide)

      # A card that links to the big one, then a replacement of the big one
      # with a different home and other names.
      linker = card("big/linker", links: ["big/one"], store: "disk")
      bigger = %{big_card("big/one", 200) | store: "disk", aloft: true}

      for c <- both do
        assert :ok = Catalog.put_card(c, linker)
        assert :ok = Catalog.also_in(c, "big/one", "disk")
        assert :ok = Catalog.put_card(c, bigger)
      end

      assert {:ok, back} = Catalog.card(small, "big/one")
      assert back === bigger
      assert dump(small) == dump(wide)

      assert rows(small, ~S|MATCH (a:Glider {ref: "big/linker"})-[:LINKS_TO]->(b) RETURN b.known|) ==
               [[true]]

      assert rows(small, "MATCH (n:Draft) RETURN n") == []

      for c <- both, do: assert(:ok = Catalog.delete_card(c, "big/one"))
      assert dump(small) == dump(wide)

      # big/linker still links to it, so it is a stub: its ref, and known.
      assert [[keys]] = rows(small, ~S|MATCH (g:Glider {ref: "big/one"}) RETURN keys(g)|)
      assert Enum.sort(keys) == ["known", "ref"]
    end

    test "R6: a card larger than a store holds is refused, and so is a field larger than a write slice",
         %{cat: cat, dir: dir} do
      assert {:error, reason} = Catalog.put_card(cat, card("too/big", schema: big_text(262_145)))
      assert reason =~ "schema"

      many = for i <- 1..60, into: %{}, do: {"a#{i}", List.duplicate(big_text(4_096), 5)}
      assert {:error, reason} = Catalog.put_card(cat, card("too/big", attrs: many))
      assert reason =~ "larger than a store holds"
      assert not_stores(cat) == []

      small = start_catalog(dir, file: "small.gldb", slice_bytes: 65_536)
      Enum.each(stores(), &(:ok = Catalog.put_store(small, &1)))

      assert {:error, reason} =
               Catalog.put_card(small, card("too/big", schema: big_text(100_000)))

      assert reason =~ "schema"
      assert {:error, :not_found} = Catalog.card(small, "too/big")
      assert not_stores(small) == []
    end
  end

  describe "links survive" do
    test "a link to a glider with no card points at a stub that is not a glider", %{cat: cat} do
      assert :ok =
               Catalog.put_card(
                 cat,
                 card("public/site", links: ["public/glossary"], description: "glossary words")
               )

      assert [[%Glider.Node{labels: ["Glider"], props: props}]] =
               rows(cat, ~S|MATCH (g:Glider {ref: "public/glossary"}) RETURN g|)

      assert props == %{"ref" => "public/glossary", "known" => false}
      assert {:error, :not_found} = Catalog.card(cat, "public/glossary")
      assert {:ok, %{gliders: [%Card{ref: "public/site"}], next: nil}} = Catalog.list(cat)
      assert {:ok, %{gliders: []}} = Catalog.list(cat, prefix: "public/glossary")
      assert {:ok, [%{ref: "public/site"}]} = Catalog.search(cat, "glossary")
      assert Catalog.count(cat) == 1
      assert Catalog.refs_in(cat, "assets") == [%{ref: "public/site", version: nil}]
    end

    test "when the card arrives the stub becomes it, and the link still points at it",
         %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("public/site", links: ["public/glossary"]))
      glossary = card("public/glossary", description: "the words we use", store: "disk")
      assert :ok = Catalog.put_card(cat, glossary)

      assert {:ok, ^glossary} = Catalog.card(cat, "public/glossary")
      assert rows(cat, ~S|MATCH (g:Glider {ref: "public/glossary"}) RETURN g.known|) == [[true]]
      assert links_into(cat, "public/glossary") == ["public/site"]
      assert Catalog.count(cat) == 2
    end

    test "updating or putting b again never drops the links into it", %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("a/one", links: ["b/target"]))
      assert :ok = Catalog.put_card(cat, card("a/two", links: ["b/target", "a/one"]))
      assert :ok = Catalog.put_card(cat, card("b/target"))

      for changed <- [
            card("b/target", description: "changed"),
            card("b/target", description: "changed"),
            card("b/target", tags: ["moved"], store: "disk", links: ["a/one"]),
            card("b/target", labels: [%{name: "X", count: 1}], aloft: true)
          ] do
        assert :ok = Catalog.put_card(cat, changed)
        assert links_into(cat, "b/target") == ["a/one", "a/two"]
      end
    end

    test "deleting b leaves a's link pointing at a stub, and deleting a too removes the stub",
         %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("a/one", links: ["b/target"]))
      assert :ok = Catalog.put_card(cat, card("b/target", attrs: %{"owner" => "dj"}, tags: ["x"]))

      assert :ok = Catalog.delete_card(cat, "b/target")
      assert {:error, :not_found} = Catalog.card(cat, "b/target")
      assert links_into(cat, "b/target") == ["a/one"]

      assert [[keys, false]] =
               rows(cat, ~S|MATCH (g:Glider {ref: "b/target"}) RETURN keys(g), g.known|)

      assert Enum.sort(keys) == ["known", "ref"]
      assert rows(cat, "MATCH (t:Tag) RETURN t") == []
      assert Catalog.count(cat) == 1

      assert :ok = Catalog.delete_card(cat, "a/one")
      assert not_stores(cat) == []
      assert Catalog.count(cat) == 0
    end
  end

  describe "the design's example queries" do
    setup %{cat: cat} do
      cards = [
        card("engineering/code",
          labels: [%{name: "CodeEntity", count: 30_000}, %{name: "Ctx", count: 80}],
          nodes: 120_000,
          attrs: %{"visibility" => "organization"},
          links: ["public/glossary"]
        ),
        card("engineering/tools",
          labels: [%{name: "CodeEntity", count: 500}],
          nodes: 900,
          store: "disk",
          attrs: %{"visibility" => "public"}
        ),
        card("public/site",
          labels: [%{name: "Section", count: 12}],
          nodes: 40,
          attrs: %{"visibility" => "public"},
          links: ["public/glossary", "engineering/code"]
        ),
        card("public/handbook", nodes: 10, attrs: %{"visibility" => "public"}, store: "disk"),
        card("public/glossary", nodes: 7, attrs: %{"visibility" => "public"})
      ]

      assert :ok = Catalog.put_cards(cat, cards)
      :ok
    end

    test "which gliders hold code, and where are they kept", %{cat: cat} do
      assert rows(cat, """
             MATCH (g:Glider)-[:HAS_LABEL]->(:Label {name: "CodeEntity"}), (g)-[:HOMED_IN]->(s:Store)
             RETURN g.ref, s.name, g.nodes ORDER BY g.nodes DESC
             """) == [["engineering/code", "assets", 120_000], ["engineering/tools", "disk", 900]]
    end

    test "everything public in the assets bucket", %{cat: cat} do
      rows =
        rows(
          cat,
          ~S|MATCH (g:Glider)-[:HOMED_IN]->(:Store {name: "assets"}) WHERE g.visibility = "public" RETURN g.ref|
        )

      assert Enum.sort(rows) == [["public/glossary"], ["public/site"]]
    end

    test "what links to the glossary", %{cat: cat} do
      rows =
        rows(
          cat,
          ~S|MATCH (g:Glider)-[:LINKS_TO]->(:Glider {ref: "public/glossary"}) RETURN g.ref|
        )

      assert Enum.sort(rows) == [["engineering/code"], ["public/site"]]
    end
  end

  describe "one writer" do
    test "concurrent puts from many processes all land, and readers never see half a card",
         %{cat: cat} do
      sup = start_supervised!(Task.Supervisor)
      cards = for i <- 0..239, do: shaped(i)
      expected = Map.new(cards, &{&1.ref, &1})

      readers =
        for _ <- 1..3, do: Task.Supervisor.async(sup, fn -> read(cat, expected, 0, []) end)

      writers =
        for chunk <- Enum.chunk_every(cards, 20) do
          Task.Supervisor.async(sup, fn -> Enum.map(chunk, &Catalog.put_card(cat, &1)) end)
        end

      assert writers |> Task.await_many(60_000) |> List.flatten() |> Enum.uniq() == [:ok]
      Enum.each(readers, &send(&1.pid, :stop))
      seen = Task.await_many(readers, 60_000)

      assert Enum.flat_map(seen, &elem(&1, 1)) == []
      assert Enum.all?(seen, fn {rounds, _} -> rounds > 0 end)
      assert Catalog.count(cat) == 240

      for card <- cards do
        assert {:ok, back} = Catalog.card(cat, card.ref)
        assert back === card
      end
    end

    test "a card written in several slices is never seen half written", %{dir: dir} do
      small = start_catalog(dir, file: "small.gldb", slice_bytes: 65_536)
      Enum.each(stores(), &(:ok = Catalog.put_store(small, &1)))
      sup = start_supervised!(Task.Supervisor)
      shapes = [big_card("big/one", 80), %{big_card("big/one", 110) | tags: ["other"]}]

      readers = for _ <- 1..3, do: Task.Supervisor.async(sup, fn -> read_big(small, 0, []) end)

      for _ <- 1..2, shape <- shapes do
        assert :ok = Catalog.put_card(small, shape)
      end

      Enum.each(readers, &send(&1.pid, :stop))
      seen = Task.await_many(readers, 60_000)
      assert Enum.flat_map(seen, &elem(&1, 1)) == []
      assert Enum.all?(seen, fn {rounds, _} -> rounds > 0 end)
    end
  end

  describe "R2: the catalog can be rebuilt" do
    test "R2: deleting the file, then putting the same stores and cards, answers every query as before",
         %{dir: dir} do
      path = Path.join(dir, "rebuilt.gldb")
      first = start_supervised!({Catalog, path: path}, id: :first)
      Enum.each(stores(), &(:ok = Catalog.put_store(first, &1)))
      assert :ok = Catalog.touch_store(first, "assets", 1_763_400_000)

      pool = for i <- 1..30, do: "kb/g#{i}"
      links = pool ++ ["kb/missing-one", "kb/missing-two"]

      for _ <- 1..60 do
        ref = Enum.random(pool)

        if :rand.uniform(8) == 1,
          do: :ok = Catalog.delete_card(first, ref),
          else: :ok = Catalog.put_card(first, random_card(ref, links))
      end

      before = answers(first)
      stop_supervised!(:first)
      for file <- Path.wildcard(path <> "*"), do: File.rm_rf!(file)

      second = start_supervised!({Catalog, path: path}, id: :second)
      Enum.each(before.stores, &(:ok = Catalog.put_store(second, &1)))
      assert :ok = Catalog.put_cards(second, before.cards)

      assert answers(second) == before
    end
  end

  describe "reopening" do
    test "stopping and starting on the same file keeps everything, the full-text index too",
         %{dir: dir} do
      path = Path.join(dir, "kept.gldb")
      first = start_supervised!({Catalog, path: path}, id: :first)
      Enum.each(stores(), &(:ok = Catalog.put_store(first, &1)))
      pool = for i <- 1..20, do: "kept/g#{i}"
      assert :ok = Catalog.put_cards(first, Enum.map(pool, &random_card(&1, pool)))
      assert :ok = Catalog.put_card(first, card("kept/volcano", description: "about volcanoes"))

      before = answers(first)
      assert [%{ref: "kept/volcano"}] = before.searches["volcanoes"]
      stop_supervised!(:first)

      handler = "catalog-index-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:glider, :query, :start], &__MODULE__.indexing/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)

      second = start_supervised!({Catalog, path: path}, id: :second)
      assert answers(second) == before
      # The index came back with the file: starting again did not build it.
      refute_received {:indexed, ^second}

      assert {:ok, %{message: message}} =
               Catalog.find(second, "CALL context.search(query: $q, label: $l)",
                 q: "volcanoes",
                 l: "Glider"
               )

      assert message =~ "text index"
    end

    test "a catalog that is killed lets go of its file, so another starts on it at once",
         %{dir: dir} do
      path = Path.join(dir, "killed.gldb")

      pid =
        start_supervised!(
          Supervisor.child_spec({Catalog, path: path}, id: :doomed, restart: :temporary)
        )

      Enum.each(stores(), &(:ok = Catalog.put_store(pid, &1)))
      assert :ok = Catalog.put_card(pid, card("a/b"))

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert {:noproc, _} = catch_exit(Catalog.db(pid))

      again = start_catalog(dir, file: "killed.gldb")
      assert {:ok, %Card{ref: "a/b"}} = Catalog.card(again, "a/b")
    end
  end

  describe "search" do
    setup %{cat: cat} do
      cards = [
        card("geo/compiler", description: "nothing about rocks"),
        card("geo/rocks", description: "about volcanoes and the rocks they leave"),
        card("geo/minerals", labels: [%{name: "Mineral", count: 9}]),
        card("geo/flows", types: [%{name: "ERUPTS_FROM", count: 4}]),
        card("geo/field", tags: ["geology"], links: ["geo/volcano-atlas"]),
        card("geo/graph-theory",
          description: "graph theory: graph colouring, graph minors",
          tags: ["graph"]
        ),
        card("geo/mixed", description: "one graph among other things")
      ]

      assert :ok = Catalog.put_cards(cat, cards)
      :ok
    end

    test "search finds a card by a word of its ref, its description, a label, a type and a tag",
         %{cat: cat} do
      assert first_hit(cat, "compiler") == "geo/compiler"
      assert first_hit(cat, "volcanoes") == "geo/rocks"
      assert first_hit(cat, "Mineral") == "geo/minerals"
      assert first_hit(cat, "ERUPTS_FROM") == "geo/flows"
      assert first_hit(cat, "geology") == "geo/field"

      assert {:ok, [%{card: %Card{ref: "geo/rocks", store: "assets"}, score: score} | _]} =
               Catalog.search(cat, "volcanoes")

      assert is_float(score)
    end

    test "search puts the best match first", %{cat: cat} do
      assert {:ok, [%{ref: "geo/graph-theory"}, %{ref: "geo/mixed"}]} =
               Catalog.search(cat, "graph")
    end

    test "search never finds a stub, and text with no word finds nothing", %{cat: cat} do
      assert {:ok, hits} = Catalog.search(cat, "atlas")
      refute Enum.any?(hits, &(&1.ref == "geo/volcano-atlas"))
      assert {:ok, []} = Catalog.search(cat, "!!! ---")
      assert {:ok, []} = Catalog.search(cat, "")
      assert {:error, _} = Catalog.search(cat, "rocks", top: 0)
      assert {:error, _} = Catalog.search(cat, "rocks", limit: 5)
      assert {:error, _} = Catalog.search(cat, <<255>>)
    end

    test "search keeps looking past stubs that rank above the card", %{cat: cat} do
      # Forty short stubs named for the word outrank one long description
      # that uses it once.
      stubs = for i <- 1..40, do: "atlas/stub-#{i}"
      assert :ok = Catalog.put_card(cat, card("maps/linker", links: stubs))

      long = Enum.map_join(1..30, " ", &"word#{&1}") <> " atlas"
      assert :ok = Catalog.put_card(cat, card("maps/real", description: long))

      assert {:ok, [%{ref: "maps/real"}]} = Catalog.search(cat, "atlas", top: 1)
    end
  end

  describe "a thousand cards" do
    @tag :scale
    test "a thousand cards are put, paged by a hundred and found by label, quickly", %{cat: cat} do
      cards = for i <- 1..1_000, do: scale_card(i)

      {put, :ok} = :timer.tc(fn -> Catalog.put_cards(cat, cards) end)
      {paged, refs} = :timer.tc(fn -> page_refs(cat, 100) end)

      {found, rows} =
        :timer.tc(fn ->
          rows(cat, """
          MATCH (g:Glider)-[:HAS_LABEL]->(:Label {name: "Label3"}), (g)-[:HOMED_IN]->(s:Store)
          RETURN g.ref, s.name, g.nodes ORDER BY g.nodes DESC
          """)
        end)

      {listed, {:ok, %{gliders: by_label}}} =
        :timer.tc(fn -> Catalog.list(cat, label: "Label3", limit: 500) end)

      {searched, {:ok, [hit | _]}} = :timer.tc(fn -> Catalog.search(cat, "g0420") end)

      assert refs == cards |> Enum.map(& &1.ref) |> Enum.sort()
      holding = Enum.filter(cards, fn c -> Enum.any?(c.labels, &(&1.name == "Label3")) end)
      assert length(rows) == length(holding)
      assert Enum.map(by_label, & &1.ref) == holding |> Enum.map(& &1.ref) |> Enum.sort()
      assert hit.ref == "scale/g0420"
      assert Catalog.count(cat) == 1_000

      if System.get_env("AEROTOW_TIMES") do
        IO.puts(
          "\nthousand cards: put_cards #{ms(put)} ms, ten pages of 100 #{ms(paged)} ms, " <>
            "find by label #{ms(found)} ms (#{length(rows)} rows), list by label #{ms(listed)} ms, " <>
            "search #{ms(searched)} ms"
        )
      end

      assert put < 10_000_000
      assert paged < 5_000_000
      assert found < 1_000_000
    end
  end

  describe "input is checked" do
    test "a card whose store the catalog does not have is refused", %{cat: cat} do
      assert {:error, reason} = Catalog.put_card(cat, card("a/b", store: "nowhere"))
      assert reason =~ "nowhere"
      assert {:error, :not_found} = Catalog.card(cat, "a/b")

      assert {:error, _} =
               Catalog.put_cards(cat, [card("a/ok"), card("a/b", store: "nowhere"), card("a/c")])

      assert Catalog.count(cat) == 0
    end

    test "R6: what is not a card glider can hold is refused before anything is written",
         %{cat: cat} do
      for bad <- [
            :not_a_card,
            %{ref: "a/b"},
            %{card("a/b") | ref: "../etc"},
            %{card("a/b") | store: nil},
            %{card("a/b") | aloft: :yes},
            %{card("a/b") | tags: ["Not A Tag"]},
            %{card("a/b") | attrs: %{"known" => true}},
            %{card("a/b") | attrs: %{"owner" => %{"nested" => 1}}},
            %{card("a/b") | attrs: %{"big" => @int_max + 1}},
            %{card("a/b") | nodes: -1},
            %{card("a/b") | nodes: @int_max + 1},
            %{card("a/b") | flight: 0},
            %{card("a/b") | labels: [%{name: <<255>>, count: 1}]},
            %{card("a/b") | labels: [%{name: "A"}]},
            %{card("a/b") | types: "CALLS"},
            %{card("a/b") | extensions: [1]},
            %{card("a/b") | schema: <<255>>},
            %{card("a/b") | generation: String.duplicate("f", 65)}
          ] do
        assert {:error, reason} = Catalog.put_card(cat, bad), inspect(bad)
        assert is_binary(reason)
        assert {:error, _} = Catalog.put_cards(cat, [card("a/fine"), bad])
      end

      assert Catalog.count(cat) == 0
    end

    test "values with quotes, backslashes and braces go in as parameters and come back",
         %{cat: cat} do
      for {text, i} <- Enum.with_index(@hostile) do
        store = %{name: "store " <> text, kind: :dir, url: "/srv/" <> text, cas: true}
        assert :ok = Catalog.put_store(cat, store)

        card =
          card("hostile/c#{i}.x_y-z",
            description: text,
            tags: ["a:b", "c.d", "e_f", "g-h"],
            attrs: %{"note" => text, "owners" => [text, text <> "!"]},
            labels: [%{name: text, count: i}],
            types: [%{name: "T" <> text, count: i}],
            indexes: [%{name: ":L(" <> text <> ")", count: i}],
            extensions: [text],
            schema: text,
            generation: String.slice(text, 0, 64),
            store: store.name
          )

        assert :ok = Catalog.put_card(cat, card)
        assert {:ok, back} = Catalog.card(cat, card.ref)
        assert back === card

        assert rows(cat, "MATCH (g:Glider)-[:HAS_LABEL]->(:Label {name: $n}) RETURN g.ref",
                 n: text
               ) ==
                 [[card.ref]]

        assert {:ok, %{gliders: [%Card{ref: ref}]}} =
                 Catalog.list(cat, store: store.name, where: %{"note" => text})

        assert ref == card.ref
      end

      recorded = Map.new(Catalog.stores(cat), &{&1.name, &1.url})
      for text <- @hostile, do: assert(recorded["store " <> text] == "/srv/" <> text)
    end

    test "R1: strings that are not refs, and hostile names, find nothing and change nothing",
         %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("safe/one", tags: ["code"], links: ["safe/two"]))
      before = dump(cat)

      for text <- @hostile do
        assert {:error, :not_found} = Catalog.card(cat, text)
        assert {:ok, %{gliders: []}} = Catalog.list(cat, tag: text)
        assert {:ok, %{gliders: []}} = Catalog.list(cat, label: text)
        assert {:ok, %{gliders: []}} = Catalog.list(cat, type: text)
        assert {:ok, %{gliders: []}} = Catalog.list(cat, store: text)
        assert {:ok, %{gliders: []}} = Catalog.list(cat, where: %{"visibility" => text})
        assert {:error, _} = Catalog.list(cat, prefix: text)
        assert {:error, _} = Catalog.list(cat, after: text)
        assert {:ok, _} = Catalog.search(cat, text)
        assert Catalog.refs_in(cat, text) == []
        assert {:ok, []} = Catalog.delete_store(cat, text)
        assert :ok = Catalog.touch_store(cat, text, 1)
        assert :ok = Catalog.delete_card(cat, text)
        assert {:error, :not_found} = Catalog.set_aloft(cat, text, true)
        assert {:error, :not_found} = Catalog.also_in(cat, "safe/one", text)
        assert {:error, _} = Catalog.put_card(cat, %Card{ref: "safe/" <> text, store: "assets"})
      end

      assert dump(cat) == before
    end
  end

  describe "stores" do
    test "delete_store removes the store, its gliders and their edges, and promotes nothing",
         %{cat: cat} do
      assert :ok =
               Catalog.put_cards(cat, [
                 card("a/x", labels: [%{name: "OnlyX", count: 1}], tags: ["x-only"]),
                 card("a/y", links: ["b/z"], labels: [%{name: "Shared", count: 1}]),
                 card("b/z", store: "disk", labels: [%{name: "Shared", count: 2}]),
                 card("b/w", store: "disk", links: ["a/y"])
               ])

      assert :ok = Catalog.also_in(cat, "a/x", "disk")

      assert {:ok, ["a/x", "a/y"]} = Catalog.delete_store(cat, "assets")

      assert Enum.map(Catalog.stores(cat), & &1.name) == ["disk"]
      assert {:error, :not_found} = Catalog.card(cat, "a/x")
      assert {:error, :not_found} = Catalog.card(cat, "a/y")
      assert {:ok, %Card{store: "disk"}} = Catalog.card(cat, "b/z")
      # a/x was also seen in disk; it is gone, not moved there.
      assert Catalog.refs_in(cat, "disk") == [
               %{ref: "b/w", version: nil},
               %{ref: "b/z", version: nil}
             ]

      assert rows(cat, ~S|MATCH (g:Glider {ref: "a/x"}) RETURN g|) == []
      # b/w links to a/y, which is a stub again, with nothing of its card.
      assert [[keys, false]] =
               rows(cat, ~S|MATCH (g:Glider {ref: "a/y"}) RETURN keys(g), g.known|)

      assert Enum.sort(keys) == ["known", "ref"]
      assert links_into(cat, "a/y") == ["b/w"]
      assert rows(cat, "MATCH (l:Label) RETURN l.name") == [["Shared"]]
      assert rows(cat, "MATCH (t:Tag) RETURN t.name") == []
      assert rows(cat, "MATCH (g)-[e:ALSO_IN]->() RETURN g") == []
      assert {:ok, []} = Catalog.delete_store(cat, "assets")
    end

    test "R4: a store is recorded without credentials", %{cat: cat} do
      assert :ok =
               Catalog.put_store(cat, %{
                 name: "minio",
                 kind: :s3,
                 url: "http://AKIAKEY:SECRETKEY@minio.internal:9000/graphs",
                 cas: false,
                 secret_access_key: "SECRETKEY",
                 token: "TOKENVALUE",
                 config: %{password: "PASSWORD"}
               })

      assert %{name: "minio", kind: :s3, url: "http://minio.internal:9000/graphs", cas: false} =
               Enum.find(Catalog.stores(cat), &(&1.name == "minio"))

      everything = inspect(dump(cat), limit: :infinity, printable_limit: :infinity)

      for secret <- ["AKIAKEY", "SECRETKEY", "TOKENVALUE", "PASSWORD"],
          do: refute(everything =~ secret)
    end

    test "put_store updates a store and keeps scanned_at unless it is given; touch_store sets it",
         %{cat: cat} do
      assert [
               %{
                 name: "assets",
                 kind: :s3,
                 url: "s3://graphs/gliders",
                 cas: true,
                 scanned_at: nil
               },
               %{name: "disk", kind: :file, url: "/var/lib/gliders", cas: true, scanned_at: nil}
             ] = Catalog.stores(cat)

      assert :ok = Catalog.touch_store(cat, "assets", 1_763_400_000)
      assert :ok = Catalog.put_store(cat, %{name: "assets", kind: "dir", url: "/srv/b", cas: nil})

      assert %{name: "assets", kind: :dir, url: "/srv/b", cas: nil, scanned_at: 1_763_400_000} =
               hd(Catalog.stores(cat))

      assert :ok =
               Catalog.put_store(cat, %{
                 name: "assets",
                 kind: :dir,
                 url: "/srv/b",
                 cas: true,
                 scanned_at: 1_763_400_500
               })

      assert %{scanned_at: 1_763_400_500, cas: true} = hd(Catalog.stores(cat))
    end

    test "put_store refuses what is not a store", %{cat: cat} do
      for bad <- [
            nil,
            %{name: "x"},
            %{name: "", kind: :dir, url: "/x"},
            %{name: "x", kind: :ftp, url: "/x"},
            %{name: "x", kind: :dir, url: 1},
            %{name: "x", kind: :dir, url: "/x", cas: "yes"},
            %{name: "x", kind: :dir, url: "/x", scanned_at: "today"},
            %{name: <<255>>, kind: :dir, url: "/x"}
          ] do
        assert {:error, reason} = Catalog.put_store(cat, bad)
        assert is_binary(reason)
      end

      assert length(Catalog.stores(cat)) == 2
    end
  end

  describe "scans" do
    test "replace_store_cards adds, updates and removes, and refs_in returns the versions it kept",
         %{cat: cat} do
      [a, b, c] = for r <- ~w(s/a s/b s/c), do: card(r, store: nil)

      assert {:ok, %{added: 3, updated: 0, removed: 0, conflicts: []}} =
               Catalog.replace_store_cards(cat, "assets", [a, b, c], %{
                 "s/a" => "1",
                 "s/b" => "1",
                 "s/c" => "1"
               })

      assert {:ok, %Card{store: "assets", aloft: false}} = Catalog.card(cat, "s/a")

      assert Catalog.refs_in(cat, "assets") == [
               %{ref: "s/a", version: "1"},
               %{ref: "s/b", version: "1"},
               %{ref: "s/c", version: "1"}
             ]

      changed = %{a | description: "changed"}

      assert {:ok, %{added: 0, updated: 1, removed: 1, conflicts: []}} =
               Catalog.replace_store_cards(cat, "assets", [changed, b], %{
                 "s/a" => "2",
                 "s/b" => "2"
               })

      assert {:ok, %Card{description: "changed"}} = Catalog.card(cat, "s/a")
      assert {:error, :not_found} = Catalog.card(cat, "s/c")

      assert Catalog.refs_in(cat, "assets") == [
               %{ref: "s/a", version: "2"},
               %{ref: "s/b", version: "2"}
             ]

      # Refs the scan listed but did not read again are left as they are.
      before = dump(cat)

      assert {:ok, %{added: 0, updated: 0, removed: 0, conflicts: []}} =
               Catalog.replace_store_cards(cat, "assets", [], %{"s/a" => "2", "s/b" => "2"})

      assert dump(cat) == before
    end

    test "replace_store_cards leaves a glider aloft here untouched", %{cat: cat} do
      assert {:ok, %{added: 2}} =
               Catalog.replace_store_cards(cat, "assets", [card("s/up"), card("s/down")], %{})

      assert :ok = Catalog.set_aloft(cat, "s/up", true)
      changed = card("s/up", description: "from the store")

      assert {:ok, %{added: 0, updated: 0, removed: 1}} =
               Catalog.replace_store_cards(cat, "assets", [changed], %{"s/up" => "9"})

      assert {:ok, %Card{description: nil, aloft: true}} = Catalog.card(cat, "s/up")
      assert {:error, :not_found} = Catalog.card(cat, "s/down")

      assert {:ok, %{removed: 0}} = Catalog.replace_store_cards(cat, "assets", [], %{})
      assert {:ok, %Card{aloft: true}} = Catalog.card(cat, "s/up")
    end

    test "a card whose ref is homed in another store is a conflict, recorded as ALSO_IN",
         %{cat: cat} do
      home = card("s/x", store: "disk", description: "the one homed in disk")
      assert :ok = Catalog.put_card(cat, home)
      seen = card("s/x", description: "a copy in assets")

      assert {:ok, %{added: 0, updated: 0, removed: 0, conflicts: ["s/x"]}} =
               Catalog.replace_store_cards(cat, "assets", [seen], %{"s/x" => "7"})

      assert {:ok, ^home} = Catalog.card(cat, "s/x")
      assert Catalog.refs_in(cat, "assets") == [%{ref: "s/x", version: "7"}]
      assert Catalog.refs_in(cat, "disk") == [%{ref: "s/x", version: nil}]

      assert {:ok, %{conflicts: ["s/x"]}} =
               Catalog.replace_store_cards(cat, "assets", [seen], %{"s/x" => "8"})

      assert Catalog.refs_in(cat, "assets") == [%{ref: "s/x", version: "8"}]
      assert rows(cat, "MATCH (g:Glider)-[e:ALSO_IN]->(s:Store) RETURN s.name") == [["assets"]]

      # Gone from the store's listing: no longer also seen there.
      assert {:ok, %{conflicts: []}} = Catalog.replace_store_cards(cat, "assets", [], %{})
      assert Catalog.refs_in(cat, "assets") == []
      assert {:ok, ^home} = Catalog.card(cat, "s/x")
    end

    test "replace_store_cards does not take a card glider cannot hold, and leaves its glider as it is",
         %{cat: cat} do
      good = card("s/good")
      assert {:ok, %{added: 1}} = Catalog.replace_store_cards(cat, "assets", [good], %{})

      bad = %{card("s/good") | nodes: @int_max + 1}

      assert {:ok, %{added: 0, updated: 0, removed: 0}} =
               Catalog.replace_store_cards(cat, "assets", [bad, :junk], %{})

      assert {:ok, ^good} = Catalog.card(cat, "s/good")
      assert {:error, _} = Catalog.replace_store_cards(cat, "nowhere", [], %{})
      assert {:error, _} = Catalog.replace_store_cards(cat, "assets", [], %{"s/good" => 7})
    end
  end

  describe "list" do
    test "list pages in ref order, and a page starts after the ref before it", %{cat: cat} do
      refs = for i <- 1..23, do: "p/g#{String.pad_leading("#{i}", 2, "0")}"
      assert :ok = Catalog.put_cards(cat, Enum.map(Enum.shuffle(refs), &card/1))

      assert page_refs(cat, 5) == refs
      assert {:ok, %{gliders: page, next: "p/g05"}} = Catalog.list(cat, limit: 5)
      assert Enum.map(page, & &1.ref) == Enum.take(refs, 5)

      # Gliders added before and after the cursor while somebody pages.
      assert :ok = Catalog.put_cards(cat, [card("p/g00"), card("p/g05b"), card("p/zz")])
      assert {:ok, %{gliders: page}} = Catalog.list(cat, limit: 3, after: "p/g05")
      assert Enum.map(page, & &1.ref) == ["p/g05b", "p/g06", "p/g07"]

      assert {:ok, %{gliders: [_ | _] = all, next: nil}} = Catalog.list(cat, limit: 600)
      assert length(all) == 26
      assert {:ok, %{gliders: default}} = Catalog.list(cat)
      assert length(default) == 26
    end

    test "list filters by store, tag, label, type, prefix and attrs, all of which must hold",
         %{cat: cat} do
      assert :ok =
               Catalog.put_cards(cat, [
                 card("engineering/code",
                   tags: ["code"],
                   labels: [%{name: "CodeEntity", count: 1}],
                   types: [%{name: "CALLS", count: 1}],
                   attrs: %{"visibility" => "public", "priority" => 1}
                 ),
                 card("engineering/tools",
                   tags: ["code", "tools"],
                   store: "disk",
                   attrs: %{"visibility" => "public", "priority" => 2}
                 ),
                 card("engineering-old/code",
                   tags: ["code"],
                   attrs: %{"visibility" => "private"}
                 ),
                 card("public/site", labels: [%{name: "CodeEntity", count: 9}])
               ])

      assert listed(cat, store: "disk") == ["engineering/tools"]

      assert listed(cat, tag: "code") == [
               "engineering-old/code",
               "engineering/code",
               "engineering/tools"
             ]

      assert listed(cat, label: "CodeEntity") == ["engineering/code", "public/site"]
      assert listed(cat, type: "CALLS") == ["engineering/code"]
      assert listed(cat, prefix: "engineering") == ["engineering/code", "engineering/tools"]
      assert listed(cat, prefix: "engineering/") == ["engineering/code", "engineering/tools"]
      assert listed(cat, prefix: "engineering/code") == ["engineering/code"]
      assert listed(cat, prefix: "") == listed(cat, [])

      assert listed(cat, where: %{"visibility" => "public"}) == [
               "engineering/code",
               "engineering/tools"
             ]

      assert listed(cat, where: [visibility: "public", priority: 2]) == ["engineering/tools"]

      assert listed(cat, tag: "code", store: "assets", label: "CodeEntity") == [
               "engineering/code"
             ]

      assert listed(cat, tag: "code", label: "Nothing") == []
    end

    test "list refuses options it does not know and values it cannot use", %{cat: cat} do
      for bad <- [
            [limit: 0],
            [limit: "10"],
            [after: "../x"],
            [prefix: "Upper/Case"],
            [prefix: 7],
            [tag: 7],
            [where: %{"known" => false}],
            [where: %{"Not-A-Name" => 1}],
            [where: %{"visibility" => %{"a" => 1}}],
            [where: %{{:a, :tuple} => 1}],
            [where: Map.new(1..65, &{"a#{&1}", 1})],
            [where: "visibility"],
            [order: :desc],
            :not_a_list
          ] do
        assert {:error, reason} = Catalog.list(cat, bad), inspect(bad)
        assert is_binary(reason)
      end
    end
  end

  describe "cards" do
    test "put_card moves a glider to a new home, which is then not also its second store",
         %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("m/x"))
      assert :ok = Catalog.also_in(cat, "m/x", "disk")
      assert Catalog.refs_in(cat, "disk") == [%{ref: "m/x", version: nil}]

      moved = card("m/x", store: "disk")
      assert :ok = Catalog.put_card(cat, moved)
      assert {:ok, ^moved} = Catalog.card(cat, "m/x")
      assert Catalog.refs_in(cat, "assets") == []

      assert rows(cat, ~S|MATCH (g:Glider {ref: "m/x"})-[e]->(s:Store) RETURN type(e), s.name|) ==
               [["HOMED_IN", "disk"]]
    end

    test "put_cards takes the later of two cards for one ref", %{cat: cat} do
      assert :ok =
               Catalog.put_cards(cat, [
                 card("d/x", description: "first"),
                 card("d/y"),
                 card("d/x", description: "second")
               ])

      assert {:ok, %Card{description: "second"}} = Catalog.card(cat, "d/x")
      assert Catalog.count(cat) == 2
    end

    test "set_aloft records aloft for a known glider, and a stub or a stranger is not found",
         %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("f/x", links: ["f/stub"]))
      assert :ok = Catalog.set_aloft(cat, "f/x", true)
      assert {:ok, %Card{aloft: true}} = Catalog.card(cat, "f/x")
      assert :ok = Catalog.set_aloft(cat, "f/x", false)
      assert {:ok, %Card{aloft: false}} = Catalog.card(cat, "f/x")
      assert {:error, :not_found} = Catalog.set_aloft(cat, "f/stub", true)
      assert {:error, :not_found} = Catalog.set_aloft(cat, "f/nobody", true)
      assert {:error, :not_found} = Catalog.set_aloft(cat, "Not/A/Ref", true)
    end

    test "also_in records a second store once, and never the home", %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("f/x", links: ["f/stub"]))
      assert :ok = Catalog.also_in(cat, "f/x", "disk")
      assert :ok = Catalog.also_in(cat, "f/x", "disk")
      assert :ok = Catalog.also_in(cat, "f/x", "assets")

      assert rows(cat, "MATCH (g:Glider)-[:ALSO_IN]->(s:Store) RETURN g.ref, s.name") == [
               ["f/x", "disk"]
             ]

      assert {:error, :not_found} = Catalog.also_in(cat, "f/stub", "disk")
      assert {:error, :not_found} = Catalog.also_in(cat, "f/x", "nowhere")
      assert {:ok, %Card{store: "assets"}} = Catalog.card(cat, "f/x")
    end

    test "delete_card of a ref with no card leaves the catalog as it is", %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("f/x", links: ["f/stub"]))
      before = dump(cat)
      assert :ok = Catalog.delete_card(cat, "f/stub")
      assert :ok = Catalog.delete_card(cat, "f/nobody")
      assert :ok = Catalog.delete_card(cat, "../x")
      assert dump(cat) == before
    end
  end

  describe "the process" do
    test "readers get the handle and their answers while the catalog is busy", %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("busy/x", description: "busy bees"))
      :ok = :sys.suspend(cat)

      try do
        assert {:ok, %Card{ref: "busy/x"}} = Catalog.card(cat, "busy/x")
        assert {:ok, %{gliders: [%Card{ref: "busy/x"}]}} = Catalog.list(cat)
        assert {:ok, [%{ref: "busy/x"}]} = Catalog.search(cat, "bees")
        assert {:ok, %{rows: [[1]]}} = Catalog.find(cat, "MATCH (g:Glider) RETURN count(g)")
        assert Catalog.count(cat) == 1
        assert [_, _] = Catalog.stores(cat)
      after
        :sys.resume(cat)
      end
    end

    test "a catalog started with a name is read and written through the name", %{dir: dir} do
      name = :"aerotow_catalog_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Catalog, path: Path.join(dir, "named.gldb"), name: name})
      Enum.each(stores(), &(:ok = Catalog.put_store(name, &1)))
      assert :ok = Catalog.put_card(name, card("n/x"))
      assert {:ok, %Card{ref: "n/x"}} = Catalog.card(name, "n/x")
      assert Catalog.db(name) == Catalog.db(pid)
    end

    test "db/1 exits when no catalog of that name runs" do
      assert {:noproc, _} = catch_exit(Catalog.db(:no_catalog_runs_here))
    end

    test "a catalog that cannot open its file, or is given bad options, does not start",
         %{dir: dir} do
      start_catalog(dir, file: "taken.gldb")
      assert {:error, error} = start_supervised({Catalog, path: Path.join(dir, "taken.gldb")})
      assert inspect(error) =~ "locked"
      assert {:error, _} = start_supervised({Catalog, path: nil})

      assert {:error, _} =
               start_supervised({Catalog, path: Path.join(dir, "x.gldb"), slice_bytes: 0})
    end

    test "find runs a statement with parameters, and refuses parameters it cannot pass",
         %{cat: cat} do
      assert :ok = Catalog.put_card(cat, card("q/x"))

      assert {:ok, %{rows: [["q/x"]]}} =
               Catalog.find(cat, "MATCH (g:Glider {ref: $r}) RETURN g.ref", r: "q/x")

      assert {:ok, %{rows: [["q/x"]]}} =
               Catalog.find(cat, "MATCH (g:Glider {ref: $r}) RETURN g.ref", %{"r" => "q/x"})

      assert {:error, _} = Catalog.find(cat, "MATCH (g:Glider {ref: $r}) RETURN g.ref")
      assert {:error, _} = Catalog.find(cat, "NOT A STATEMENT")
      assert {:error, _} = Catalog.find(cat, "MATCH (g) RETURN g", [1, 2])
      assert {:error, _} = Catalog.find(cat, "MATCH (g) RETURN g", %{1 => 2})
      assert {:error, _} = Catalog.find(cat, :not_text, %{})
    end
  end

  # ------------------------------------------------------------------ helpers

  def indexing(_event, _measurements, %{query: query}, test) do
    if query =~ "context.index", do: send(test, {:indexed, self()})
  end

  defp start_catalog(dir, opts \\ []) do
    {file, opts} = Keyword.pop(opts, :file, "catalog.gldb")
    start_supervised!({Catalog, [path: Path.join(dir, file)] ++ opts}, id: make_ref())
  end

  defp stores do
    [
      %{name: "assets", kind: :s3, url: "s3://graphs/gliders", cas: true},
      %{name: "disk", kind: :file, url: "/var/lib/gliders", cas: true}
    ]
  end

  # A card as Aerotow.Card makes one, homed in assets unless told otherwise.
  defp card(ref, fields \\ []) do
    {set, rest} = Keyword.split(fields, [:description, :tags, :attrs, :links, :mode, :hot])
    {:ok, card} = Card.new(ref, set)
    struct!(card, Keyword.merge([store: "assets"], rest))
  end

  defp full_card(ref) do
    card(ref,
      description: Enum.join(@texts, " | "),
      tags: Enum.map(1..64, &"t#{&1}"),
      attrs:
        Map.new(Enum.with_index(@attr_values), fn {value, i} -> {"a#{i}", value} end)
        |> Map.put("visibility", "public"),
      links: ["outside/one", ref, "outside/two"],
      mode: :disk,
      hot: 1_048_576,
      nodes: 112_015,
      edges: 240_311,
      bytes: 268_435_456,
      labels: Enum.map(Enum.sort(@labels), &%{name: &1, count: 29_515}),
      types: Enum.map(Enum.sort(@types), &%{name: &1, count: 82_073}),
      indexes: Enum.map(Enum.sort(@indexes), &%{name: &1, count: 7}),
      extensions: ["context"],
      schema: "# schema: 2 nodes\n(:CodeEntity) 2 {path:text}\n",
      flight: 7,
      generation: "96348bfb24205901aabbccddeeff0011",
      position: 1_048_665,
      created_at: 1_763_400_000,
      updated_at: 1_763_400_100,
      described_at: 1_763_400_100,
      store: "disk",
      aloft: true
    )
  end

  # A card with every field chosen at random from values that are hard to
  # keep: unicode, quotes, the edges of 64 bits, empty lists.
  defp random_card(ref, links) do
    attrs =
      @attr_names
      |> Enum.take_random(Enum.random(0..5))
      |> Map.new(&{&1, Enum.random(@attr_values)})

    card(ref,
      description: Enum.random([nil | @texts]),
      tags: Enum.take_random(@tags, Enum.random(0..4)),
      attrs: attrs,
      links: Enum.take_random(links, Enum.random(0..3)),
      mode: Enum.random(~w(auto memory disk)),
      hot: Enum.random([nil, 0, 1_048_576]),
      nodes: Enum.random([0, 7, 120_000, @int_max]),
      edges: Enum.random([0, 3, 250_000]),
      bytes: Enum.random([0, 4_096, 268_435_456]),
      labels: random_counts(@labels),
      types: random_counts(@types),
      indexes: random_counts(@indexes),
      extensions: Enum.random([[], ["context"]]),
      schema: Enum.random([nil, "# schema: 2 nodes\n(:CodeEntity) 2 {path:text}\n" | @texts]),
      flight: Enum.random([nil, 1, 7]),
      generation: Enum.random([nil, "96348bfb24205901aabbccddeeff0011"]),
      position: Enum.random([nil, 0, 1_048_665]),
      created_at: Enum.random([nil, 1_763_400_000]),
      updated_at: Enum.random([nil, 1_763_400_100]),
      described_at: Enum.random([nil, 1_763_400_100]),
      store: Enum.random(["assets", "disk"]),
      aloft: Enum.random([true, false])
    )
  end

  defp random_counts(names) do
    names
    |> Enum.take_random(Enum.random(0..4))
    |> Enum.sort()
    |> Enum.map(&%{name: &1, count: Enum.random([0, 1, 29_515, @int_max])})
  end

  # A card with `n` labels and types, and links, attrs and a schema to
  # match: more than one write slice of 64 KiB holds.
  defp big_card(ref, n) do
    card(ref,
      description: "a wide graph",
      tags: ["wide", "big"],
      attrs: %{"visibility" => "public", "owners" => Enum.map(1..20, &"owner #{&1}")},
      links: [ref | Enum.map(1..div(n, 3), &"#{ref}-link-#{&1}")],
      labels: Enum.map(1..n, &%{name: "Label#{&1}", count: &1}),
      types: Enum.map(1..n, &%{name: "TYPE_#{&1}", count: &1 * 2}),
      indexes: Enum.map(1..10, &%{name: ":Label#{&1}(key)", count: &1}),
      schema: big_text(40_000),
      nodes: n * 100
    )
  end

  defp big_text(bytes),
    do: String.duplicate("schema line\n", div(bytes, 12) + 1) |> binary_part(0, bytes)

  # Every card of this shape has one home, three labels, two types, two tags
  # and one link out: nine edges out, whenever it can be seen at all.
  defp shaped(i) do
    card("load/g#{i}",
      tags: ["t#{rem(i, 5)}", "u#{rem(i, 3)}"],
      links: ["load/g#{rem(i + 1, 240)}"],
      labels: [
        %{name: "A#{rem(i, 4)}", count: i},
        %{name: "B#{rem(i, 6)}", count: 1},
        %{name: "C", count: 2}
      ],
      types: [%{name: "T#{rem(i, 3)}", count: i}, %{name: "U", count: 0}],
      attrs: %{"n" => i}
    )
  end

  defp read(cat, expected, rounds, wrong) do
    receive do
      :stop -> {rounds, wrong}
    after
      0 ->
        {:ok, %{rows: rows}} =
          Catalog.find(cat, "MATCH (g:Glider)-[:HOMED_IN]->(:Store) RETURN g.ref, outdegree(g)")

        half = for [ref, out] <- rows, out != 9, do: {ref, out}

        {:ok, %{gliders: page}} =
          Catalog.list(cat, limit: 10, after: Enum.random(["load/g1", "load/g3"]))

        changed = for card <- page, card !== expected[card.ref], do: card.ref
        read(cat, expected, rounds + 1, half ++ changed ++ wrong)
    end
  end

  defp read_big(cat, rounds, wrong) do
    receive do
      :stop -> {rounds, wrong}
    after
      0 ->
        {:ok, %{rows: rows}} =
          Catalog.find(
            cat,
            "MATCH (g:Glider {ref: $r})-[:HOMED_IN]->(:Store) RETURN g.labels, g.types, g.tags, g.links, outdegree(g)",
            r: "big/one"
          )

        half =
          for [labels, types, tags, links, out] <- rows,
              out !=
                1 + div(length(labels), 2) + div(length(types), 2) + length(tags) + length(links),
              do: {labels |> length() |> div(2), out}

        drafts =
          for [n] <- rows(cat, "MATCH (n:Glider) WHERE n.draft IS NOT NULL RETURN n.ref"),
              do: {:draft, n}

        read_big(cat, rounds + 1, half ++ drafts ++ wrong)
    end
  end

  defp scale_card(i) do
    n = String.pad_leading("#{i}", 4, "0")

    card("scale/g#{n}",
      description: "glider number g#{n} of a thousand",
      tags: ["tag#{rem(i, 8)}", "set#{rem(i, 3)}"],
      links: ["scale/g#{String.pad_leading("#{rem(i * 7, 1_000) + 1}", 4, "0")}"],
      labels:
        Enum.map(
          Enum.uniq([rem(i, 20), rem(i * 3, 20), rem(i * 7, 20)]),
          &%{name: "Label#{&1}", count: i}
        ),
      types: Enum.map(Enum.uniq([rem(i, 10), rem(i * 3, 10)]), &%{name: "TYPE_#{&1}", count: i}),
      attrs: %{"visibility" => Enum.at(["public", "private", "organization"], rem(i, 3))},
      nodes: i * 10,
      store: Enum.at(["assets", "disk"], rem(i, 2))
    )
  end

  defp page_refs(cat, limit, after_ref \\ nil, acc \\ []) do
    opts = if after_ref, do: [limit: limit, after: after_ref], else: [limit: limit]
    {:ok, %{gliders: page, next: next}} = Catalog.list(cat, opts)
    acc = acc ++ Enum.map(page, & &1.ref)
    if next, do: page_refs(cat, limit, next, acc), else: acc
  end

  defp listed(cat, opts) do
    {:ok, %{gliders: page}} = Catalog.list(cat, opts)
    Enum.map(page, & &1.ref)
  end

  defp first_hit(cat, text) do
    {:ok, [%{ref: ref} | _]} = Catalog.search(cat, text)
    ref
  end

  defp links_into(cat, ref) do
    cat
    |> rows("MATCH (g:Glider)-[:LINKS_TO]->(:Glider {ref: $r}) RETURN g.ref", r: ref)
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  # Every node that is not a store.
  defp not_stores(cat),
    do: for([labels, n] <- rows(cat, "MATCH (n) RETURN labels(n), n"), labels != ["Store"], do: n)

  defp rows(cat, cypher, params \\ %{}) do
    {:ok, %{rows: rows}} = Catalog.find(cat, cypher, params)
    rows
  end

  defp export(cat) do
    {:ok, jsonl} = Glider.export_jsonl(Catalog.db(cat))
    jsonl
  end

  # The whole catalog as plain data with no ids in it: each node by its
  # labels and properties, each edge by its type, its properties and the
  # nodes at its ends. Two catalogs with the same dump answer a query alike.
  defp dump(cat) do
    nodes = for [n] <- rows(cat, "MATCH (n) RETURN n"), do: {Enum.sort(n.labels), n.props}

    edges =
      for [a_labels, a, e, b_labels, b] <-
            rows(
              cat,
              "MATCH (a)-[e]->(b) RETURN labels(a), coalesce(a.ref, a.name), e, labels(b), coalesce(b.ref, b.name)"
            ),
          do: {{Enum.sort(a_labels), a}, e.type, e.props, {Enum.sort(b_labels), b}}

    {Enum.sort(nodes), Enum.sort(edges)}
  end

  # What every reader sees: the whole graph, the stores, every card, pages,
  # the design's queries, searches (scores, best first, ties by ref).
  defp answers(cat) do
    {:ok, %{gliders: cards}} = Catalog.list(cat, limit: 500)

    %{
      dump: dump(cat),
      stores: Catalog.stores(cat),
      cards: cards,
      count: Catalog.count(cat),
      pages: page_refs(cat, 7),
      tagged: Enum.map(@tags, &listed(cat, tag: &1)),
      labelled: Enum.map(@labels, &listed(cat, label: &1)),
      refs_in: Enum.map(stores(), &Catalog.refs_in(cat, &1.name)),
      links:
        rows(cat, "MATCH (a:Glider)-[:LINKS_TO]->(b:Glider) RETURN a.ref, b.ref, b.known")
        |> Enum.sort(),
      searches:
        Map.new(
          ["code", "graph", "volcanoes", "public", "CodeEntity", "glider", "outside"],
          fn word ->
            {:ok, hits} = Catalog.search(cat, word, top: 50)
            {word, Enum.sort_by(hits, &{-&1.score, &1.ref})}
          end
        )
    }
  end

  defp ms(microseconds), do: div(microseconds, 1_000)
end
