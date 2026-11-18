defmodule Aerotow.CardTest do
  # Not async: one test counts the VM's atoms, and modules running beside it
  # (code loading, NIFs answering for the first time) make atoms of their own.
  use ExUnit.Case, async: false

  alias Aerotow.Card

  doctest Aerotow.Card

  defp full do
    {:ok, card} =
      Card.new("engineering/code",
        description: "the \"code\" graph\nline two",
        tags: ["code", "big"],
        attrs: %{
          "visibility" => "organization",
          "priority" => 3,
          "ratio" => 0.5,
          "live" => true,
          "owners" => ["a", "b"]
        },
        links: ["public/glossary", "public/a"],
        mode: :disk,
        hot: 1_048_576
      )

    %{
      card
      | nodes: 112_015,
        edges: 240_311,
        bytes: 268_435_456,
        labels: [%{name: "CodeEntity", count: 29_515}, %{name: "Ctx", count: 82_500}],
        types: [%{name: "CALLS", count: 82_073}],
        indexes: [%{name: ":CodeEntity(path)", count: 29_515}],
        extensions: ["context"],
        schema: "# schema: 2 nodes\n(:CodeEntity) 2 {path:text}\n",
        flight: 7,
        generation: "96348bfb24205901aabbccddeeff0011",
        position: 1_048_665,
        created_at: 1_763_400_000,
        updated_at: 1_763_400_100,
        described_at: 1_763_400_100
    }
  end

  describe "new/2 and change/2" do
    test "sorts and dedupes tags and links" do
      {:ok, card} = Card.new("a", tags: ["b", "a", "b"], links: ["z/y", "a/b", "z/y"])
      assert card.tags == ["a", "b"]
      assert card.links == ["a/b", "z/y"]
    end

    test "takes a map or a keyword list, atom or string keys" do
      assert {:ok, %Card{description: "x"}} = Card.new("a", %{"description" => "x"})
      assert {:ok, %Card{description: "x"}} = Card.new("a", description: "x")
      assert {:error, reason} = Card.new("a", [1, 2])
      assert reason =~ "map or a keyword"
    end

    test "refuses a bad ref, a typo, and fields a flight owns" do
      assert {:error, _} = Card.new("../a")
      assert {:error, reason} = Card.new("a", descripton: "x")
      assert reason =~ "descripton"
      assert {:error, _} = Card.new("a", nodes: 3)
      assert {:error, _} = Card.new("a", flight: 3)
    end

    test "refuses attrs that take aerotow's names or are not flat" do
      for name <- Card.reserved() do
        assert {:error, reason} = Card.new("a", attrs: %{name => "x"}), name
        assert reason =~ "aerotow uses" or reason =~ "not an attr name"
      end

      assert {:error, _} = Card.new("a", attrs: %{"Bad" => 1})
      assert {:error, _} = Card.new("a", attrs: %{"x-y" => 1})
      assert {:error, reason} = Card.new("a", attrs: %{"owner" => %{"nested" => 1}})
      assert reason =~ "not flat"
      assert {:error, _} = Card.new("a", attrs: %{"owners" => [1, 2]})
      assert {:error, _} = Card.new("a", attrs: [1, 2])
      assert {:error, _} = Card.new("a", attrs: "x")
      assert {:error, _} = Card.new("a", attrs: %{"x" => nil})
    end

    test "refuses wrong shapes and sizes instead of crashing" do
      assert {:error, _} = Card.new("a", description: 1)
      assert {:error, _} = Card.new("a", description: String.duplicate("x", 4_097))
      assert {:error, _} = Card.new("a", description: <<255>>)
      assert {:error, _} = Card.new("a", tags: "code")
      assert {:error, _} = Card.new("a", tags: ["Code"])
      assert {:error, _} = Card.new("a", tags: [1])
      assert {:error, _} = Card.new("a", tags: Enum.map(1..65, &"t#{&1}"))
      assert {:error, _} = Card.new("a", links: ["../x"])
      assert {:error, _} = Card.new("a", links: "x")
      assert {:error, _} = Card.new("a", mode: "ram")
      assert {:error, _} = Card.new("a", mode: nil)
      assert {:error, _} = Card.new("a", hot: -1)
      assert {:error, _} = Card.new("a", hot: 1.5)
    end

    test "change/2 keeps what it was not asked to change" do
      card = full()
      assert {:ok, changed} = Card.change(card, description: nil, hot: nil)
      assert changed == %{card | description: nil, hot: nil}
    end
  end

  describe "encode/1 and decode/1" do
    test "a card comes back as it went" do
      card = full()
      assert Card.decode(Card.encode(card)) == {:ok, card}
      {:ok, empty} = Card.new("a")
      assert Card.decode(Card.encode(empty)) == {:ok, empty}
    end

    test "the same card is the same bytes, whatever order it was built in" do
      {:ok, a} = Card.new("a", attrs: %{"x" => 1, "y" => 2}, tags: ["p", "q"])
      {:ok, b} = Card.new("a", tags: ["q", "p"], attrs: [y: 2, x: 1])
      assert Card.encode(a) == Card.encode(b)
    end

    test "where this instance found it is not part of the stored card" do
      card = %{full() | store: "assets", aloft: true}
      refute Card.encode(card) =~ "assets"
      assert {:ok, %Card{store: nil, aloft: false}} = Card.decode(Card.encode(card))
    end

    test "it is JSON a person can read: one field a line" do
      json = Card.encode(full())
      assert String.starts_with?(json, "{\n  \"format\": 1,\n  \"ref\": \"engineering/code\",\n")
      assert String.ends_with?(json, "\n}\n")

      assert %{"ref" => "engineering/code", "attrs" => %{"owners" => ["a", "b"]}} =
               JSON.decode!(json)
    end

    test "fields it does not know are ignored" do
      map = full() |> Card.encode() |> JSON.decode!() |> Map.put("future", %{"x" => [1]})
      assert Card.decode(JSON.encode!(map)) == {:ok, full()}
    end

    test "refuses another format, a bad ref, and what is not a card" do
      ok = full() |> Card.encode() |> JSON.decode!()
      assert {:error, reason} = Card.decode(JSON.encode!(%{ok | "format" => 2}))
      assert reason =~ "format"
      assert {:error, _} = Card.decode(JSON.encode!(Map.delete(ok, "format")))
      assert {:error, _} = Card.decode(JSON.encode!(%{ok | "ref" => "../../etc"}))
      assert {:error, _} = Card.decode(JSON.encode!(Map.delete(ok, "ref")))
      assert {:error, _} = Card.decode("[]")
      assert {:error, _} = Card.decode("not json")
      assert {:error, _} = Card.decode("")
      assert {:error, reason} = Card.decode(String.duplicate(" ", 1_048_577))
      assert reason =~ "too large"
    end

    test "garbage in any field is an error or a default, never a crash and never an atom" do
      ok = full() |> Card.encode() |> JSON.decode!()
      before = :erlang.system_info(:atom_count)

      junk = [
        nil,
        true,
        -1,
        1.5,
        "zz-not-an-atom-#{System.unique_integer()}",
        [],
        [1],
        [[1]],
        %{},
        %{"a" => %{"b" => 1}},
        [%{"name" => 1}]
      ]

      for {key, _} <- ok, value <- junk do
        case Card.decode(JSON.encode!(Map.put(ok, key, value))) do
          {:ok, %Card{}} -> :ok
          {:error, reason} when is_binary(reason) -> :ok
        end
      end

      assert :erlang.system_info(:atom_count) == before
    end

    test "counts that are not counts are refused" do
      ok = full() |> Card.encode() |> JSON.decode!()

      assert {:error, _} =
               Card.decode(JSON.encode!(%{ok | "labels" => [%{"name" => "A", "count" => -1}]}))

      assert {:error, _} = Card.decode(JSON.encode!(%{ok | "labels" => [%{"name" => "A"}]}))
      assert {:error, _} = Card.decode(JSON.encode!(%{ok | "types" => "x"}))
    end
  end

  describe "observe/1" do
    test "reads counts, labels, types, indexes and extensions from a glider" do
      {:ok, db} = Glider.open()

      {:ok, _} =
        Glider.run(
          db,
          ~S|CREATE (a:Person {name:"Ada"})-[:KNOWS {since:2019}]->(b:Person {name:"Bob"})|
        )

      {:ok, _} = Glider.run(db, ~S|CREATE (:Machine {name:"Analytical Engine"})|)
      {:ok, _} = Glider.run(db, "INDEX ON :Person(name)")

      assert {:ok, obs} = Card.observe(db)
      assert obs.nodes == 3
      assert obs.edges == 1
      assert obs.labels == [%{name: "Machine", count: 1}, %{name: "Person", count: 2}]
      assert obs.types == [%{name: "KNOWS", count: 1}]
      assert obs.indexes == [%{name: ":Person(name)", count: 2}]
      assert obs.extensions == []
      assert obs.schema == nil
      assert is_integer(obs.bytes)

      :ok = Glider.Context.install(db)
      assert {:ok, %{extensions: ["context"], schema: schema}} = Card.observe(db)
      assert schema =~ "(:Person)"
      Glider.close(db)
    end

    test "an observation goes on a card with the time it was made" do
      {:ok, db} = Glider.open()
      {:ok, _} = Glider.run(db, ~S|CREATE (:Person {name:"Ada"})|)
      {:ok, obs} = Card.observe(db)
      {:ok, card} = Card.new("a", description: "kept")
      card = Card.put_observation(card, obs, 1_763_400_000)

      assert %Card{
               nodes: 1,
               description: "kept",
               described_at: 1_763_400_000,
               updated_at: 1_763_400_000
             } = card

      assert Card.decode(Card.encode(card)) == {:ok, card}
      Glider.close(db)
    end

    test "a closed glider is an error" do
      {:ok, db} = Glider.open()
      Glider.close(db)
      assert {:error, _} = Card.observe(db)
    end
  end
end
