defmodule Aerotow.Store.FileTest do
  # Not async: the first store in a VM loads code and makes atoms, and
  # Aerotow.CardTest counts the VM's atoms while it runs.
  use ExUnit.Case, async: false

  alias Aerotow.{Card, Ref, Store}
  alias Aerotow.Store.File, as: FileStore

  @moduletag :tmp_dir

  @glider_files ~w(.gldb .gldb-wal .gldb-data .gldb-stream .gldb-tmp .gldb.lock)

  defp file_store(dir) do
    {:ok, store} = Store.new("disk", Path.join(dir, "disk"), kind: :file)
    store
  end

  defp card!(ref, opts \\ []) do
    {:ok, card} = Card.new(ref, opts)
    card
  end

  # Every file and directory under `root`, relative to it.
  defp tree(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp write!(root, relative, body \\ "x") do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  # A database glider made, holding one node, and its card.
  defp glider!(store, ref) do
    path = FileStore.path(store, ref)
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Glider.open(path)
    {:ok, _} = Glider.run(db, "CREATE (:N {ref: $ref})", ref: ref)
    Glider.close(db)
    :ok = Store.write_card(store, card!(ref, description: "the glider #{ref}"))
  end

  defp holds?(store, ref) do
    {:ok, db} = Glider.open(FileStore.path(store, ref))
    {:ok, %{rows: rows}} = Glider.query(db, "MATCH (n:N) RETURN n.ref")
    Glider.close(db)
    rows == [[ref]]
  end

  defp random_ref do
    ref = Enum.map_join(1..Enum.random(1..8), "/", fn _ -> random_segment() end)
    if Ref.valid?(ref), do: ref, else: random_ref()
  end

  defp random_segment do
    alnum = ~c"abcdefghijklmnopqrstuvwxyz0123456789"
    inner = ~c"abcdefghijklmnopqrstuvwxyz0123456789._-"

    case Enum.random(0..14) do
      0 ->
        <<Enum.random(alnum)>>

      n ->
        to_string(
          [Enum.random(alnum)] ++ for(_ <- 1..n, do: Enum.random(inner)) ++ [Enum.random(alnum)]
        )
    end
  end

  test "a file store makes no marker and holds no objects", %{tmp_dir: dir} do
    store = file_store(dir)
    assert %Store{kind: :file, cas: nil, id: nil} = store
    assert File.ls!(store.config.root) == []
    assert {:error, :not_objects} = Store.list(store, "")
  end

  test "path/2 is inside the root for every ref, and refuses what is not one", %{tmp_dir: dir} do
    store = file_store(dir)
    root = store.config.root
    long = Enum.map_join(1..4, "/", fn _ -> String.duplicate("a", 63) end)

    refs =
      ["a", "engineering/code", "a/b/c/d/e/f/g/h", "x.y-z_0", long] ++
        for(_ <- 1..500, do: random_ref())

    for ref <- refs do
      path = FileStore.path(store, ref)
      assert path == Path.join(root, ref <> ".gldb")
      assert Path.expand(path) == path
      assert String.starts_with?(path, root <> "/")
    end

    for bad <- ["../x", "a/../../x", "/etc/passwd", "a//b", ".hidden", "A", "a.gldb", nil] do
      assert_raise ArgumentError, fn -> FileStore.path(store, bad) end
    end
  end

  test "a card is kept beside its database, and read back with the store's name", %{tmp_dir: dir} do
    store = file_store(dir)
    card = card!("engineering/code", tags: ["code"])

    assert :ok = Store.write_card(store, card)

    assert File.read!(Path.join(store.config.root, "engineering/code.card.json")) ==
             Card.encode(card)

    assert {:ok, read} = Store.read_card(store, "engineering/code")
    assert read == %{card | store: "disk"}
    assert {:error, :not_found} = Store.read_card(store, "engineering/other")
  end

  test "list_cards/1 finds cards at any depth, and nothing that is not one", %{tmp_dir: dir} do
    store = file_store(dir)
    root = store.config.root
    refs = ["a", "a/b", "a/b/c/d/e/f/g/h", "x.card", "z/y.json"]
    for ref <- refs, do: :ok = Store.write_card(store, card!(ref))

    # A database with no card is not a glider aerotow knows yet.
    write!(root, "orphan.gldb", "")

    # Glider's own directories, and names no ref has.
    for path <- [
          "a.gldb-wal/x.card.json",
          "a.gldb-stream/0/y.card.json",
          "Upper.card.json",
          "a/_flights.card.json",
          "card.json",
          "a/b/.hidden.card.json",
          "Caps/d.card.json",
          "a/b/c/d/e/f/g/h/i.card.json"
        ],
        do: write!(root, path, "{}")

    assert {:ok, listed} = Store.list_cards(store)
    assert Enum.map(listed, & &1.ref) == Enum.sort(refs)
    assert Enum.all?(listed, &is_binary(&1.version))
  end

  test "a card's version changes when its bytes do", %{tmp_dir: dir} do
    store = file_store(dir)
    :ok = Store.write_card(store, card!("a"))
    :ok = Store.write_card(store, card!("b"))
    {:ok, before} = Store.list_cards(store)
    assert Store.list_cards(store) == {:ok, before}

    :ok = Store.write_card(store, card!("a", description: "changed"))
    {:ok, [a, b]} = Store.list_cards(store)
    refute a.version == Enum.at(before, 0).version
    assert b.version == Enum.at(before, 1).version
  end

  test "R6: in a file store too, a card that is garbage or names another ref is refused, and the others are listed",
       %{tmp_dir: dir} do
    store = file_store(dir)
    root = store.config.root
    :ok = Store.write_card(store, card!("good"))
    write!(root, "garbage.card.json", "{ not json")
    write!(root, "copied.card.json", Card.encode(card!("good")))
    write!(root, "future.card.json", JSON.encode!(%{"format" => 2, "ref" => "future"}))

    for ref <- ["garbage", "copied", "future"] do
      assert {:error, reason} = Store.read_card(store, ref)
      assert is_binary(reason)
    end

    assert {:ok, %Card{ref: "good", store: "disk"}} = Store.read_card(store, "good")
    assert {:ok, listed} = Store.list_cards(store)
    assert "good" in Enum.map(listed, & &1.ref)
  end

  test "deleting a card deletes the card and nothing else", %{tmp_dir: dir} do
    store = file_store(dir)
    glider!(store, "a")
    before = tree(store.config.root)

    assert :ok = Store.delete_card(store, "a")
    assert before -- tree(store.config.root) == ["a.card.json"]
    assert {:error, :not_found} = Store.read_card(store, "a")
    assert :ok = Store.delete_card(store, "a")
    assert :ok = Store.delete_card(store, "never/there")
  end

  test "purge/2 removes the database, the files glider keeps beside it and the card, and nothing else",
       %{tmp_dir: dir} do
    store = file_store(dir)
    root = store.config.root
    glider!(store, "a")
    glider!(store, "a/b")

    # Every name glider keeps beside a database, whether or not this one has
    # made it yet.
    for {suffix, inside} <- [
          {".gldb-wal", "0000000000000000.wal"},
          {".gldb-data", "00000001.seg"},
          {".gldb-stream", "0123456789abcdef/segments/0000000000000000.seg"},
          {".gldb-tmp", "adj-0"}
        ],
        do: write!(root, Path.join("a" <> suffix, inside), "glider's")

    write!(root, "a.gldb.lock", "123")

    # Names that are not the glider a.
    for path <- ["a.txt", "a.gldbx", "ab.gldb", "ab.card.json", "notes/a.gldb", "a.card.json.bak"],
        do: write!(root, path)

    before = tree(root)
    assert :ok = Store.purge(store, "a")

    gone =
      for path <- before,
          path == "a.card.json" or
            Enum.any?(
              @glider_files,
              &(path == "a" <> &1 or String.starts_with?(path, "a" <> &1 <> "/"))
            ),
          do: path

    assert tree(root) == before -- gone
    refute File.exists?(FileStore.path(store, "a"))

    # The glider a/b, in the directory a/, is whole; ab's card is ab's.
    assert holds?(store, "a/b")
    assert {:ok, %Card{ref: "a/b"}} = Store.read_card(store, "a/b")
    assert {:ok, listed} = Store.list_cards(store)
    assert Enum.map(listed, & &1.ref) == ["a/b", "ab"]

    assert :ok = Store.purge(store, "a")
    assert :ok = Store.purge(store, "never/there")
  end

  test "the gliders a and a/b are independent: their cards, their listing, a purge of either",
       %{tmp_dir: dir} do
    store = file_store(dir)
    glider!(store, "a")
    glider!(store, "a/b")
    assert {:ok, [%{ref: "a"}, %{ref: "a/b"}]} = Store.list_cards(store)

    assert :ok = Store.purge(store, "a/b")
    assert holds?(store, "a")
    assert {:ok, %Card{ref: "a"}} = Store.read_card(store, "a")
    assert {:ok, [%{ref: "a"}]} = Store.list_cards(store)
    refute File.exists?(FileStore.path(store, "a/b"))

    glider!(store, "a/b")
    assert :ok = Store.purge(store, "a")
    assert holds?(store, "a/b")
    assert {:ok, [%{ref: "a/b"}]} = Store.list_cards(store)
  end

  test "a symbolic link inside the root is never followed", %{tmp_dir: dir} do
    outside = Path.join(dir, "outside")
    write!(outside, "x.card.json", Card.encode(card!("link/x")))
    write!(outside, "x.gldb", "a database")
    store = file_store(dir)
    root = store.config.root
    File.ln_s!(outside, Path.join(root, "link"))
    File.ln_s!(Path.join(outside, "x.card.json"), Path.join(root, "y.card.json"))

    assert {:ok, []} = Store.list_cards(store)
    assert {:error, :not_found} = Store.read_card(store, "link/x")
    assert {:error, :not_found} = Store.read_card(store, "y")

    assert {:error, reason} = Store.write_card(store, card!("link/x"))
    assert reason =~ "symbolic link"
    assert :ok = Store.delete_card(store, "link/x")
    assert :ok = Store.purge(store, "link/x")

    # The links are still there, and so is everything they point at.
    assert File.ls!(outside) |> Enum.sort() == ["x.card.json", "x.gldb"]
    assert File.lstat!(Path.join(root, "link")).type == :symlink
    assert File.read!(Path.join(outside, "x.card.json")) == Card.encode(card!("link/x"))
  end
end
