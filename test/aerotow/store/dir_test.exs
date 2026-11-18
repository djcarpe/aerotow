defmodule Aerotow.Store.DirTest do
  # Not async: the first store, listing and replication in a VM load code
  # and make atoms, and Aerotow.CardTest counts the VM's atoms while it runs.
  use ExUnit.Case, async: false

  import Aerotow.ObjectsCase

  alias Aerotow.Store
  alias Aerotow.Store.{Dir, Layout}

  doctest Aerotow.Store.Dir

  @moduletag :tmp_dir

  objects_conformance(fn %{tmp_dir: dir} ->
    {:ok, store} = Store.new("dir", Path.join(dir, "store"))
    store
  end)

  defp store(dir) do
    {:ok, store} = Store.new("dir", Path.join(dir, "store"))
    store
  end

  defp keys(store, prefix \\ "") do
    {:ok, %{objects: objects}} = Store.list(store, prefix)
    Enum.map(objects, & &1.key)
  end

  # Whether this process can read a directory it has taken every permission
  # from: as root it can, and the tests that rely on permissions say nothing.
  defp permissions_hold?(dir) do
    probe = Path.join(dir, "permissions")
    File.mkdir_p!(probe)
    File.chmod!(probe, 0o000)
    held = match?({:error, :eacces}, File.ls(probe))
    File.chmod!(probe, 0o755)
    held
  end

  describe "the directory" do
    test "is created, with its parents, when it does not exist; a file is not one", %{
      tmp_dir: dir
    } do
      deep = Path.join(dir, "a/b/c")
      assert {:ok, %{root: ^deep}} = Dir.init("s", deep, [])
      assert File.dir?(deep)
      assert {:ok, %{root: ^deep}} = Dir.init("s", "file://" <> deep, [])

      file = Path.join(dir, "plain")
      File.write!(file, "x")
      assert {:error, reason} = Dir.init("s", file, [])
      assert reason =~ "is a file"

      assert {:error, _} = Dir.init("s", Path.join(file, "below"), [])
      assert {:error, _} = Dir.init("s", "", [])
      assert {:error, _} = Dir.init("s", "file://", [])
    end

    test "an object is the file at its key under the root, holding its body", %{tmp_dir: dir} do
      store = store(dir)
      :ok = Store.put(store, "cards/a/b.json", "the card")
      assert File.read!(Path.join(store.config.root, "cards/a/b.json")) == "the card"
      assert {:ok, "the card"} = Store.get(store, "cards/a/b.json")
    end

    test "replica/2 is the directory under the root", %{tmp_dir: dir} do
      store = store(dir)
      prefix = Layout.flight_data("eng/code", 3)
      assert Store.replica(store, prefix) == {Path.join(store.config.root, prefix), []}
      assert_raise ArgumentError, fn -> Dir.replica(store.config, "../x") end
    end

    test "an object's version is its file's modification time, size and inode", %{tmp_dir: dir} do
      store = store(dir)
      :ok = Store.put(store, "t/k", "body")
      stat = File.lstat!(Path.join(store.config.root, "t/k"), time: :posix)

      assert {:ok, %{objects: [%{key: "t/k", size: 4, version: version}]}} =
               Store.list(store, "t/")

      assert version == Dir.version(stat)
    end
  end

  describe "puts" do
    test "an exclusive put that finds the key taken leaves the file as it was", %{tmp_dir: dir} do
      store = store(dir)
      path = Path.join(store.config.root, "t/k")
      :ok = Store.put(store, "t/k", "first")
      before = File.lstat!(path, time: :posix)

      assert {:error, :exists} = Store.put(store, "t/k", "second", exclusive: true)
      now = File.lstat!(path, time: :posix)

      assert {now.inode, now.mtime, now.size, now.links} ==
               {before.inode, before.mtime, before.size, 1}

      assert File.read!(path) == "first"
    end

    test "puts, won or lost, leave no temporary file behind", %{tmp_dir: dir} do
      store = store(dir)

      for round <- 1..10 do
        1..16
        |> Enum.map(fn i ->
          Task.async(fn -> Store.put(store, "race/#{round}", "racer #{i}", exclusive: true) end)
        end)
        |> Task.await_many(30_000)
      end

      for i <- 1..10, do: :ok = Store.put(store, "plain", "body #{i}")

      assert File.ls!(Path.join(store.config.root, ".aerotow-tmp")) == []
    end

    test "a file where a directory would be, or a directory where an object would be, is an answer",
         %{tmp_dir: dir} do
      store = store(dir)
      :ok = Store.put(store, "x", "an object")

      assert {:error, reason} = Store.put(store, "x/y", "below it")
      assert reason =~ "x is an object"
      assert {:error, _} = Store.put(store, "x/y", "below it", exclusive: true)
      assert {:error, :not_found} = Store.get(store, "x/y")
      assert :ok = Store.delete(store, "x/y")
      assert {:ok, %{objects: [], prefixes: []}} = Store.list(store, "x/")

      :ok = Store.put(store, "d/e", "inside")
      assert {:error, :not_found} = Store.get(store, "d")
      assert :ok = Store.delete(store, "d")
      assert {:error, reason} = Store.put(store, "d", "over it")
      assert reason =~ "directory"
      assert {:error, reason} = Store.put(store, "d", "over it", exclusive: true)
      assert reason =~ "directory"
      assert {:ok, "inside"} = Store.get(store, "d/e")
    end
  end

  describe "deletes" do
    test "remove the directories they leave empty, up to the root, which stays", %{tmp_dir: dir} do
      store = store(dir)
      root = store.config.root
      :ok = Store.put(store, "a/b/c/d", "deep")
      :ok = Store.put(store, "a/kept", "kept")

      assert :ok = Store.delete(store, "a/b/c/d")
      refute File.exists?(Path.join(root, "a/b"))
      assert File.read!(Path.join(root, "a/kept")) == "kept"

      assert :ok = Store.delete(store, "a/kept")
      refute File.exists?(Path.join(root, "a"))
      assert File.dir?(root)
      assert keys(store) == ["aerotow.json"]
    end

    test "a directory with no object under it is not listed as a prefix", %{tmp_dir: dir} do
      store = store(dir)
      # Left by something else: glider's own retention deletes files and
      # leaves their directories.
      File.mkdir_p!(Path.join(store.config.root, "g/empty/deeper"))
      :ok = Store.put(store, "g/full/x", "x")

      assert {:ok, %{objects: [], prefixes: ["g/full/"]}} =
               Store.list(store, "g/", delimiter: true)
    end
  end

  describe "what is not an object" do
    test "a symbolic link inside the root is never followed", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside")
      File.mkdir_p!(outside)
      secret = Path.join(outside, "secret")
      File.write!(secret, "outside the store")

      store = store(dir)
      root = store.config.root
      File.ln_s!(outside, Path.join(root, "link"))
      File.mkdir_p!(Path.join(root, "cards"))
      File.ln_s!(secret, Path.join(root, "cards/evil.json"))

      assert {:error, :not_found} = Store.get(store, "link/secret")
      assert {:error, :not_found} = Store.get(store, "cards/evil.json")

      assert {:error, reason} = Store.put(store, "link/new", "x")
      assert reason =~ "symbolic link"
      assert {:error, reason} = Store.put(store, "link/new", "x", exclusive: true)
      assert reason =~ "symbolic link"
      assert {:error, reason} = Store.put(store, "cards/evil.json", "x", exclusive: true)
      assert reason =~ "symbolic link"

      assert :ok = Store.delete(store, "link/secret")
      assert :ok = Store.delete(store, "cards/evil.json")

      assert {:ok, %{objects: [], prefixes: []}} = Store.list(store, "link/")
      assert {:ok, %{objects: [], prefixes: []}} = Store.list(store, "link/", delimiter: true)
      assert {:ok, %{objects: [], prefixes: []}} = Store.list(store, "cards/", delimiter: true)
      assert keys(store) == ["aerotow.json"]
      assert {:ok, %{prefixes: []}} = Store.list(store, "", delimiter: true)

      # A plain put at the link's own name replaces the link, not what it
      # points at.
      assert :ok = Store.put(store, "cards/evil.json", "mine")
      assert File.lstat!(Path.join(root, "cards/evil.json")).type == :regular
      assert File.read!(secret) == "outside the store"
      assert File.ls!(outside) == ["secret"]
    end

    test "names that start with a dot are the store's own: refused as keys, never listed", %{
      tmp_dir: dir
    } do
      store = store(dir)
      root = store.config.root

      for key <- [".x", "a/.x", ".aerotow-tmp/x", "a/.b/c", ".nfs0001"] do
        for result <- [
              Store.get(store, key),
              Store.put(store, key, "x"),
              Store.put(store, key, "x", exclusive: true),
              Store.delete(store, key)
            ] do
          assert {:error, reason} = result
          assert reason =~ "starting with \".\""
        end
      end

      assert {:error, _} = Store.list(store, ".aerotow-tmp/")
      assert {:error, _} = Store.list(store, "a/.")

      # A put cut short leaves its temporary file behind; other hidden names
      # are nobody's.
      :ok = Store.put(store, "a/k", "x")
      File.write!(Path.join([root, ".aerotow-tmp", "0123456789abcdef"]), "half a body")
      File.write!(Path.join(root, "a/.hidden"), "x")
      File.mkdir_p!(Path.join(root, ".snapshot/a"))
      File.write!(Path.join(root, ".snapshot/a/k"), "x")

      assert keys(store) == ["a/k", "aerotow.json"]

      assert {:ok, %{objects: [%{key: "aerotow.json"}], prefixes: ["a/"]}} =
               Store.list(store, "", delimiter: true)
    end
  end

  describe "a store that fails" do
    test "answers with a reason a person can read", %{tmp_dir: dir} do
      if permissions_hold?(dir) do
        store = store(dir)
        :ok = Store.put(store, "locked/k", "x")
        locked = Path.join(store.config.root, "locked")
        File.chmod!(locked, 0o000)
        on_exit(fn -> File.chmod(locked, 0o755) end)

        for result <- [
              Store.get(store, "locked/k"),
              Store.put(store, "locked/j", "y"),
              Store.put(store, "locked/j", "y", exclusive: true),
              Store.delete(store, "locked/k"),
              Store.list(store, "locked/"),
              Store.list(store, "")
            ] do
          assert {:error, reason} = result
          assert reason =~ "permission denied", inspect(result)
        end

        File.chmod!(locked, 0o755)
        assert {:ok, "x"} = Store.get(store, "locked/k")
      end
    end

    test "a directory that cannot be written cannot be probed, and says why", %{tmp_dir: dir} do
      if permissions_hold?(dir) do
        root = Path.join(dir, "read-only")
        File.mkdir_p!(root)
        File.chmod!(root, 0o555)
        on_exit(fn -> File.chmod(root, 0o755) end)

        assert {:error, reason} = Dir.probe(%{root: root})
        assert reason =~ "permission denied"
        assert {:error, reason} = Store.new("ro", root)
        assert reason =~ "permission denied"
      end
    end
  end
end
