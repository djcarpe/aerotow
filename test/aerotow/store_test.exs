defmodule Aerotow.StoreTest do
  # Not async: the first store in a VM loads code and makes atoms, and
  # Aerotow.CardTest counts the VM's atoms while it runs.
  use ExUnit.Case, async: false

  alias Aerotow.{Card, Store}
  alias Aerotow.Store.Layout

  doctest Aerotow.Store

  @moduletag :tmp_dir

  defp dir_store(dir, name \\ "assets", opts \\ []) do
    {:ok, store} = Store.new(name, Path.join(dir, name), opts)
    store
  end

  defp card!(ref, opts \\ []) do
    {:ok, card} = Card.new(ref, opts)
    card
  end

  describe "new/3" do
    test "a store's name is lower-case letters, digits, '_' and '-', at most 63 bytes", %{
      tmp_dir: dir
    } do
      for name <- ["a", "assets", "disk-1", "x_y", "0", String.duplicate("a", 63)] do
        assert {:ok, %Store{name: ^name}} =
                 Store.new(name, Path.join(dir, "ok-#{name}"), kind: :file)
      end

      for name <- [
            "",
            "A",
            "-a",
            "_a",
            "a b",
            "a/b",
            "a.b",
            "é",
            String.duplicate("a", 64),
            nil,
            :a
          ] do
        assert {:error, reason} = Store.new(name, Path.join(dir, "bad"), kind: :file)
        assert is_binary(reason)
      end

      refute File.exists?(Path.join(dir, "bad"))
    end

    test "the kind comes from the url, and a relative directory is expanded", %{tmp_dir: dir} do
      path = Path.join(dir, "d")
      assert {:ok, %Store{kind: :dir, url: ^path, mod: Aerotow.Store.Dir}} = Store.new("d", path)
      assert {:ok, %Store{kind: :dir, url: ^path}} = Store.new("d", "file://" <> path)
      assert {:ok, %Store{kind: :dir, url: ^path}} = Store.new("d", path, kind: :dir)

      assert {:ok, %Store{kind: :file, url: ^path, mod: Aerotow.Store.File, cas: nil, id: nil}} =
               Store.new("f", path, kind: :file)

      relative = Path.relative_to_cwd(Path.join(dir, "rel"))
      assert Path.type(relative) == :relative
      assert {:ok, %Store{url: url}} = Store.new("r", relative)
      assert url == Path.join(dir, "rel")
      assert File.dir?(url)
    end

    test "a kind that contradicts the url, or that is not a kind, is an error", %{tmp_dir: dir} do
      path = Path.join(dir, "d")

      for {url, kind} <- [
            {path, :s3},
            {path, :peer},
            {"s3://bucket/prefix", :dir},
            {"s3://bucket/prefix", :file},
            {"s3://bucket/prefix", :peer},
            {"https://west.example.com/aerotow", :dir},
            {"https://west.example.com/aerotow", :s3}
          ] do
        assert {:error, reason} = Store.new("x", url, kind: kind)
        assert reason =~ "does not match"
      end

      for kind <- [:bogus, "file", :path, 1] do
        assert {:error, reason} = Store.new("x", path, kind: kind)
        assert reason =~ "kind is"
      end

      refute File.exists?(path)
    end

    test "a url with a scheme aerotow does not know, or that is empty or not text, is an error",
         %{tmp_dir: dir} do
      for url <- [
            "ftp://host/x",
            "gs://bucket/x",
            "S3://bucket/x",
            "",
            "file://",
            <<255>>,
            "a\0b"
          ] do
        assert {:error, reason} = Store.new("x", url)
        assert is_binary(reason), inspect(url)
      end

      assert {:error, _} = Store.new("x", nil)
      assert {:error, _} = Store.new("x", Path.join(dir, "x"), [:not_an_option])
      assert {:error, _} = Store.new("x", Path.join(dir, "x"), clock: :sundial)
      refute File.exists?(Path.join(dir, "x"))
    end

    test "the s3 and peer kinds say so when they are not in this build" do
      for {url, mod} <- [
            {"s3://bucket/prefix", Aerotow.Store.S3},
            {"https://west.example.com/aerotow", Aerotow.Store.Peer}
          ],
          not Code.ensure_loaded?(mod) do
        assert {:error, reason} = Store.new("x", url)
        assert reason =~ "not available in this build"
      end
    end

    test "a directory that does not exist is created, and a path that is a file is an error",
         %{tmp_dir: dir} do
      deep = Path.join(dir, "a/b/c")
      assert {:ok, %Store{url: ^deep}} = Store.new("x", deep)
      assert File.dir?(deep)

      file = Path.join(dir, "file")
      File.write!(file, "x")

      for kind <- [:dir, :file] do
        assert {:error, reason} = Store.new("x", file, kind: kind)
        assert reason =~ "is a file"
      end
    end

    test "single_writer is kept, and is false unless given", %{tmp_dir: dir} do
      assert %Store{single_writer: false} = dir_store(dir, "a")
      assert %Store{single_writer: true} = dir_store(dir, "b", single_writer: true)
      assert {:error, reason} = Store.new("c", Path.join(dir, "c"), single_writer: "yes")
      assert reason =~ "single_writer"
    end

    test "an object store is probed, and keeps the id of its marker", %{tmp_dir: dir} do
      store = dir_store(dir, "assets", clock: fn -> 1_763_400_000_123 end)
      assert store.cas == true
      assert store.id =~ ~r/\A[0-9a-f]{32}\z/
      assert {:ok, body} = Store.get(store, Layout.marker())

      assert JSON.decode!(body) == %{
               "format" => 1,
               "id" => store.id,
               "created_at" => 1_763_400_000
             }

      # The same place again is the same store.
      assert {:ok, %Store{id: id}} = Store.new("again", store.url)
      assert id == store.id

      # A file store has no marker.
      {:ok, disk} = Store.new("disk", Path.join(dir, "disk"), kind: :file)
      assert disk.id == nil
      refute File.exists?(Path.join(disk.url, Layout.marker()))
    end

    @tag timeout: 600_000
    test "new/3 calls racing on an empty directory agree on one store id", %{tmp_dir: dir} do
      for round <- 1..6 do
        url = Path.join(dir, "race-#{round}")

        ids =
          1..6
          |> Enum.map(fn i -> Task.async(fn -> Store.new("s#{i}", url) end) end)
          |> Task.await_many(300_000)
          |> Enum.map(fn {:ok, store} -> store.id end)

        assert [_one] = Enum.uniq(ids)
      end
    end

    test "a marker of another format is refused, saying so", %{tmp_dir: dir} do
      root = Path.join(dir, "future")
      File.mkdir_p!(root)
      marker = %{"format" => 2, "id" => String.duplicate("a", 32), "created_at" => 1}
      File.write!(Path.join(root, Layout.marker()), JSON.encode!(marker))

      assert {:error, reason} = Store.new("future", root)
      assert reason =~ "is format 2"
    end

    test "a marker that is not one is refused", %{tmp_dir: dir} do
      id = String.duplicate("b", 32)

      for {name, body} <- [
            {"garbage", "not json"},
            {"list", "[1]"},
            {"no-id", ~s|{"format": 1, "created_at": 1}|},
            {"bad-id", ~s|{"format": 1, "id": "../x", "created_at": 1}|},
            {"negative", ~s|{"format": 1, "id": "#{id}", "created_at": -1}|},
            {"huge", String.duplicate(" ", 70_000)}
          ] do
        root = Path.join(dir, name)
        File.mkdir_p!(root)
        File.write!(Path.join(root, Layout.marker()), body)

        assert {:error, reason} = Store.new(name, root)
        assert reason =~ "not a store's marker", name
      end
    end
  end

  describe "R4" do
    test "R4: public/1 and inspect/1 of a store never show a credential", %{tmp_dir: dir} do
      secret = "SECRET-#{System.unique_integer([:positive])}"
      store = dir_store(dir)

      store = %{
        store
        | config:
            Map.merge(store.config, %{
              access_key_id: "AKIA" <> secret,
              secret_access_key: secret,
              token: secret
            })
      }

      for shown <- [
            inspect(store),
            inspect(Store.public(store)),
            inspect([store]),
            inspect(%{store: store}, limit: :infinity, printable_limit: :infinity)
          ] do
        refute shown =~ secret
      end

      assert inspect(store) =~ "assets"
      assert Store.public(store) == %{name: "assets", kind: :dir, url: store.url, cas: true}
    end

    test "R4: a user and password in a url are kept out of the store and out of every reason",
         %{tmp_dir: dir} do
      secret = "SECRET-#{System.unique_integer([:positive])}"

      for url <- [
            "https://user:#{secret}@west.example.com/aerotow",
            "s3://key:#{secret}@bucket/prefix",
            "ftp://user:#{secret}@host/x"
          ],
          opts <- [[], [kind: :dir], [kind: :bogus]] do
        case Store.new("x", url, opts) do
          {:error, reason} ->
            refute reason =~ secret

          {:ok, store} ->
            refute inspect(store) =~ secret
            refute inspect(Store.public(store)) =~ secret
        end
      end

      # However a store was made, public/1 leaves them out.
      store = %Store{
        name: "west",
        kind: :peer,
        url: "https://user:#{secret}@west.example.com/aerotow",
        mod: Aerotow.Store.Dir
      }

      refute Store.public(store).url =~ secret
      assert Store.public(store).url == "https://west.example.com/aerotow"
      refute File.exists?(Path.join(dir, "x"))
    end
  end

  describe "cards in an object store" do
    test "a card written is read back as it was, with the store's name", %{tmp_dir: dir} do
      store = dir_store(dir)
      card = card!("engineering/code", description: "the code graph", tags: ["code"])

      assert :ok = Store.write_card(store, card)
      assert {:ok, read} = Store.read_card(store, "engineering/code")
      assert read == %{card | store: "assets"}
      assert {:ok, json} = Store.get(store, Layout.card("engineering/code"))
      assert json == Card.encode(card)

      assert {:error, :not_found} = Store.read_card(store, "engineering/other")
      assert {:error, reason} = Store.read_card(store, "../etc")
      assert reason =~ "not a ref"
    end

    test "R6: a card that is not JSON, of another format, with a ref that does not parse, or naming another ref, is refused; the others are still listed",
         %{tmp_dir: dir} do
      store = dir_store(dir)
      good = card!("good", description: "fine")
      :ok = Store.write_card(store, good)
      json = good |> Card.encode() |> JSON.decode!()

      bad = %{
        "garbage" => "{ not json",
        "array" => "[1, 2]",
        "future" => JSON.encode!(%{json | "format" => 2, "ref" => "future"}),
        "dotted" => JSON.encode!(%{json | "ref" => "../../etc/passwd"}),
        "copied" => Card.encode(good)
      }

      for {ref, body} <- bad, do: :ok = Store.put(store, Layout.card(ref), body)

      for {ref, _body} <- bad do
        assert {:error, reason} = Store.read_card(store, ref)
        assert is_binary(reason), ref
      end

      assert {:error, reason} = Store.read_card(store, "copied")
      assert reason =~ "\"copied\""
      assert reason =~ "\"good\""

      assert {:ok, %Card{ref: "good", store: "assets"}} = Store.read_card(store, "good")
      assert {:ok, listed} = Store.list_cards(store)
      assert "good" in Enum.map(listed, & &1.ref)
    end

    test "list_cards/1 gives each card's ref and a version that changes with its bytes, and skips keys that are not cards",
         %{tmp_dir: dir} do
      store = dir_store(dir)
      for ref <- ["x/y/z", "a/b", "a"], do: :ok = Store.write_card(store, card!(ref))

      for key <- [
            "cards/BAD.json",
            "cards/a.txt",
            "cards/a/_x.json",
            "cards/a/b",
            "gliders/a.json"
          ],
          do: :ok = Store.put(store, key, "{}")

      assert {:ok, listed} = Store.list_cards(store)
      assert Enum.map(listed, & &1.ref) == ["a", "a/b", "x/y/z"]
      before = Map.new(listed, &{&1.ref, &1.version})

      :ok = Store.write_card(store, card!("a/b", description: "changed"))
      {:ok, listed} = Store.list_cards(store)
      now = Map.new(listed, &{&1.ref, &1.version})

      assert now["a"] == before["a"]
      assert now["x/y/z"] == before["x/y/z"]
      refute now["a/b"] == before["a/b"]
    end

    test "a card deleted is gone, and deleting one that is not there is :ok", %{tmp_dir: dir} do
      store = dir_store(dir)
      :ok = Store.write_card(store, card!("a"))

      assert :ok = Store.delete_card(store, "a")
      assert {:error, :not_found} = Store.read_card(store, "a")
      assert :ok = Store.delete_card(store, "a")
      assert {:error, reason} = Store.delete_card(store, "A")
      assert reason =~ "not a ref"
    end

    test "R1: a ref becomes a key only once Aerotow.Ref.parse/1 has accepted it", %{tmp_dir: dir} do
      for store <- [dir_store(dir), dir_store(dir, "disk", kind: :file)] do
        {:ok, before} = Store.list_cards(store)

        for ref <- ["../escape", "a/../../b", "/etc/passwd", "A", "a//b", "_flights", nil] do
          for result <- [
                Store.read_card(store, ref),
                Store.write_card(store, %Card{ref: ref}),
                Store.delete_card(store, ref),
                Store.purge(store, ref)
              ] do
            assert {:error, reason} = result
            assert reason =~ "not a ref", inspect(result)
          end
        end

        assert {:error, _} = Store.write_card(store, %{ref: "a"})
        assert Store.list_cards(store) == {:ok, before}
      end

      refute File.exists?(Path.join(dir, "escape"))

      assert File.ls!(Path.join(dir, "assets")) |> Enum.reject(&String.starts_with?(&1, ".")) == [
               "aerotow.json"
             ]
    end
  end

  describe "objects" do
    test "a store that does not hold objects says so", %{tmp_dir: dir} do
      {:ok, store} = Store.new("disk", Path.join(dir, "disk"), kind: :file)
      refute Store.objects?(store)
      assert {:error, :not_objects} = Store.get(store, "k")
      assert {:error, :not_objects} = Store.put(store, "k", "x")
      assert {:error, :not_objects} = Store.delete(store, "k")
      assert {:error, :not_objects} = Store.list(store, "")
      assert {:error, :not_objects} = Store.replica(store, "k")
    end

    test "options and bodies that are not what a put or a listing takes are refused", %{
      tmp_dir: dir
    } do
      store = dir_store(dir)
      assert {:error, _} = Store.put(store, "k", "x", exclusive: "yes")
      assert {:error, _} = Store.put(store, "k", "x", [:exclusive])
      assert {:error, _} = Store.put(store, "k", :body)
      assert {:error, _} = Store.put(store, "k", [:not, :iodata])
      assert {:error, _} = Store.list(store, "", delimiter: 1)
      assert {:ok, %{objects: [%{key: "aerotow.json"}]}} = Store.list(store, "")
    end

    test "probe_cas/2 finds that exclusive puts that are not exclusive give no cas, and cleans up",
         %{tmp_dir: dir} do
      store = dir_store(dir)
      {:ok, before} = Store.list(store, "")

      careless = %{
        put: fn key, body, _opts -> Store.put(store, key, body) end,
        get: &Store.get(store, &1),
        delete: &Store.delete(store, &1)
      }

      assert {:ok, %{cas: false}} = Store.probe_cas(careless)
      assert Store.list(store, "") == {:ok, before}

      careful = %{careless | put: &Store.put(store, &1, &2, &3)}
      assert {:ok, %{cas: true}} = Store.probe_cas(careful, rounds: 3, racers: 12)
      assert Store.list(store, "") == {:ok, before}
    end

    test "probe_cas/2 passes a failing store's reason on" do
      failing = %{
        put: fn _key, _body, _opts -> {:error, "the disk is on fire"} end,
        get: fn _key -> {:error, :not_found} end,
        delete: fn _key -> :ok end
      }

      assert {:error, "the disk is on fire"} = Store.probe_cas(failing)
    end

    test "probe_cas/2 makes a put that crashes while racing an error, and its caller lives on",
         %{tmp_dir: dir} do
      store = dir_store(dir)

      crashing = %{
        put: fn key, body, opts ->
          if String.contains?(key, "race"), do: raise("the store module has a bug")
          Store.put(store, key, body, opts)
        end,
        get: &Store.get(store, &1),
        delete: &Store.delete(store, &1)
      }

      assert {:error, reason} = Store.probe_cas(crashing)
      assert reason =~ "crashed"
      assert {:ok, %{objects: [%{key: "aerotow.json"}]}} = Store.list(store, "")
    end
  end
end
