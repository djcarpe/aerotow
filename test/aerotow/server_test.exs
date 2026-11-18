defmodule Aerotow.ServerTest do
  use ExUnit.Case, async: false

  import Aerotow.TowCase
  import ExUnit.CaptureLog

  alias Aerotow.{FakeS3, Instance, Lease, Options, Server, StallStore, Store}
  alias Aerotow.Flight.Copy

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"

  defp instance!(tow) do
    {:ok, instance} = Instance.fetch(tow)
    instance
  end

  defp aloft_refs(tow) do
    {:ok, infos} = Aerotow.aloft(tow)
    Enum.map(infos, & &1.ref)
  end

  # An instance whose store "store" goes through a StallStore the test controls.
  defp stalled_tow(dir, opts \\ []) do
    path = Path.join(dir, "store")
    tow = tow(Path.join(dir, "a"), [default_store: nil] ++ opts)
    {:ok, store} = Store.new("store", path)
    ctl = start_supervised!({StallStore, watcher: self()})
    {:ok, spec} = Options.store({"store", path, []})
    :ok = Server.attach_store(instance!(tow), StallStore.wrap(store, ctl), spec)
    {tow, ctl, path}
  end

  describe "9: limits" do
    test "past max_aloft the least recently used flight lands to make room", %{tmp_dir: dir} do
      {clock, set} = clock()

      tow =
        tow(dir,
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store",
          max_aloft: 2,
          clock: clock
        )

      listen([[:aerotow, :evict]])

      {:ok, _} = Aerotow.create(tow, "g/one")
      {:ok, _} = Aerotow.create(tow, "g/two")
      # Used last, a second later on the instance's clock.
      set.(clock.() + 1_000)
      {:ok, _} = Aerotow.query(tow, "g/one", "STATS")
      {:ok, _} = Aerotow.create(tow, "g/three")

      assert_received {:telemetry, [:aerotow, :evict], _, %{ref: "g/two", why: :max_aloft}}
      assert aloft_refs(tow) == ["g/one", "g/three"]
      assert {:ok, :hangared} = Aerotow.where(tow, "g/two")
    end

    test "past budget bytes of working copies the least recently used flight lands", %{
      tmp_dir: dir
    } do
      tow =
        tow(dir,
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store",
          budget: 1,
          # Working copies on disk: an empty graph in memory takes no bytes.
          mode: "disk"
        )

      listen([[:aerotow, :evict]])

      {:ok, _} = Aerotow.create(tow, "g/one")
      {:ok, _} = Aerotow.create(tow, "g/two")

      assert_received {:telemetry, [:aerotow, :evict], _, %{ref: "g/one", why: :budget}}
      assert aloft_refs(tow) == ["g/two"]
    end

    test "a pinned flight is never landed for room: the launch is :too_many_aloft", %{
      tmp_dir: dir
    } do
      tow =
        tow(dir,
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store",
          max_aloft: 1
        )

      {:ok, _} = Aerotow.create(tow, "g/one")
      :ok = Aerotow.launch(tow, "g/one", pin: true)

      assert Aerotow.create(tow, "g/two") == {:error, :too_many_aloft}
      assert aloft_refs(tow) == ["g/one"]
      assert {:ok, :hangared} != Aerotow.where(tow, "g/one")
    end

    test "a flight with something checked out is not landed for room", %{tmp_dir: dir} do
      tow =
        tow(dir,
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store",
          max_aloft: 1
        )

      {:ok, _} = Aerotow.create(tow, "g/one")
      test = self()

      holder =
        Task.async(fn ->
          Aerotow.checkout(tow, "g/one", fn _db ->
            send(test, :holding)

            receive do
              :let_go -> :ok
            end
          end)
        end)

      assert_receive :holding, 10_000
      assert Aerotow.create(tow, "g/two") == {:error, :too_many_aloft}
      send(holder.pid, :let_go)
      assert {:ok, :ok} = Task.await(holder)
      assert {:ok, _} = Aerotow.create(tow, "g/two")
      assert aloft_refs(tow) == ["g/two"]
    end
  end

  describe "10: scans" do
    setup %{tmp_dir: dir} do
      stores = [{"store", Path.join(dir, "store")}]
      a = tow(Path.join(dir, "a"), stores: stores, default_store: "store")
      b = tow(Path.join(dir, "b"), stores: stores, default_store: "store")
      %{a: a, b: b}
    end

    test "gliders created, changed and purged by another instance appear, change and go after a scan",
         %{a: a, b: b} do
      listen([[:aerotow, :scan, :stop]])

      for ref <- ["g/one", "g/two", "g/three"] do
        {:ok, _} = Aerotow.create(a, ref, tags: ["first"])
        :ok = Aerotow.land(a, ref)
      end

      assert {:ok, %{seen: 3, added: 3, read: 3}} = Aerotow.scan(b, "store")

      assert_received {:telemetry, [:aerotow, :scan, :stop],
                       %{seen: 3, added: 3, updated: 0, removed: 0}, %{store: "store"}}

      # Nothing changed: no card is read again.
      assert {:ok, %{seen: 3, read: 0, added: 0, updated: 0, removed: 0}} =
               Aerotow.scan(b, "store")

      {:ok, _} = Aerotow.update(a, "g/two", tags: ["second"])
      :ok = Aerotow.land(a, "g/two")
      :ok = Aerotow.delete(a, "g/three", purge: true)

      assert {:ok, %{seen: 2, read: 1, updated: 1, removed: 1}} = Aerotow.scan(b, "store")
      assert {:ok, %{tags: ["second"]}} = Aerotow.card(b, "g/two")
      assert Aerotow.card(b, "g/three") == {:error, :not_found}
      assert {:ok, %{gliders: [%{ref: "g/one"}, %{ref: "g/two"}]}} = Aerotow.gliders(b)
    end

    test "a purged glider is :not_found on another instance that knew it, without a scan", %{
      a: a,
      b: b
    } do
      {:ok, _} = Aerotow.create(a, @ref)
      :ok = Aerotow.land(a, @ref)
      {:ok, _} = Aerotow.scan(b, "store")
      :ok = Aerotow.delete(a, @ref, purge: true)

      assert Aerotow.query(b, @ref, "STATS") == {:error, :not_found}
      assert Aerotow.card(b, @ref) == {:error, :not_found}
    end

    test "every scan_interval each store is scanned", %{tmp_dir: dir, a: a} do
      listen([[:aerotow, :scan, :stop]])
      {:ok, _} = Aerotow.create(a, @ref)
      :ok = Aerotow.land(a, @ref)

      c =
        tow(Path.join(dir, "c"), stores: [{"store", Path.join(dir, "store")}], scan_interval: 50)

      assert_receive {:telemetry, [:aerotow, :scan, :stop], %{added: 1}, %{store: "store"}}, 5_000
      assert {:ok, %{gliders: [%{ref: @ref}]}} = Aerotow.gliders(c)
    end

    test "a scan that fails leaves the catalog as it was", %{tmp_dir: dir} do
      {tow, ctl, _path} = stalled_tow(Path.join(dir, "stalled"))
      {:ok, _} = Aerotow.create(tow, @ref, store: "store")
      :ok = Aerotow.land(tow, @ref)
      {:ok, before} = Aerotow.gliders(tow)

      StallStore.set(ctl, :list, :fail)
      assert {:error, _} = Aerotow.scan(tow, "store")
      assert {:ok, ^before} = Aerotow.gliders(tow)
    end
  end

  describe "11: stores at run time" do
    test "add_store/4 probes, records and scans a store; remove_store/2 lands its flights and forgets it",
         %{tmp_dir: dir} do
      a =
        tow(Path.join(dir, "a"),
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store"
        )

      {:ok, _} = Aerotow.create(a, @ref)
      {:ok, 1} = Aerotow.run(a, @ref, "CREATE (:N {n: 1})")
      :ok = Aerotow.land(a, @ref)

      b = tow(Path.join(dir, "b"))
      assert {:ok, []} = Aerotow.stores(b)

      assert {:ok, %{name: "store", kind: :dir, cas: true}} =
               Aerotow.add_store(b, "store", Path.join(dir, "store"))

      assert {:error, :exists} = Aerotow.add_store(b, "store", Path.join(dir, "store"))
      assert {:ok, %{gliders: [%{ref: @ref}]}} = Aerotow.gliders(b)
      assert rows(Aerotow.query(b, @ref, "MATCH (n:N) RETURN n.n")) == [[1]]
      {:ok, 1} = Aerotow.run(b, @ref, "CREATE (:N {n: 2})")

      assert :ok = Aerotow.remove_store(b, "store")
      assert {:ok, []} = Aerotow.stores(b)
      assert {:ok, []} = Aerotow.aloft(b)
      assert {:ok, %{gliders: []}} = Aerotow.gliders(b)
      assert Aerotow.query(b, @ref, "STATS") == {:error, :not_found}

      # B landed before it let go: A sees B's write.
      assert rows(Aerotow.query(a, @ref, "MATCH (n:N) RETURN n.n ORDER BY n.n")) == [[1], [2]]
      assert Aerotow.remove_store(b, "store") == {:error, :not_found}
    end

    test "a store that cannot be reached at start does not stop the instance, and is scanned when it can be",
         %{tmp_dir: dir} do
      late = Path.join(dir, "late")
      File.write!(late, "a file where the store's directory goes")
      listen([[:aerotow, :scan, :stop]])

      tow = tow(Path.join(dir, "a"), stores: [{"late", late}], default_store: "late")
      assert {:ok, [%{name: "late", available: false, reason: reason}]} = Aerotow.stores(tow)
      assert is_binary(reason)
      assert {:error, {:store_unavailable, "late", _}} = Aerotow.create(tow, @ref)

      File.rm!(late)
      assert_receive {:telemetry, [:aerotow, :scan, :stop], _, %{store: "late"}}, 10_000
      assert {:ok, [%{name: "late", available: true}]} = Aerotow.stores(tow)
      assert {:ok, _} = Aerotow.create(tow, @ref)
    end

    test "R4: no credential in stores/1, a reason, a log line, telemetry or the server's status",
         %{tmp_dir: dir} do
      {fake, s3} = s3()
      secret = Keyword.fetch!(s3, :secret_access_key)
      wrong = "wrong+secret+that+must+not+show"
      bad = Keyword.put(s3, :secret_access_key, wrong)
      id = make_ref()
      :ok = :telemetry.attach_many(id, telemetry_events(), &__MODULE__.collect/4, self())
      on_exit(fn -> :telemetry.detach(id) end)

      log =
        capture_log([level: :debug], fn ->
          tow =
            tow(Path.join(dir, "a"),
              stores: [{"assets", "s3://graphs/gliders", s3}, {"bad", "s3://graphs/other", bad}],
              default_store: "assets"
            )

          {:ok, stores} = Aerotow.stores(tow)

          assert [
                   %{name: "assets", available: true},
                   %{name: "bad", available: false, reason: reason}
                 ] = stores

          assert is_binary(reason)

          {:ok, _} = Aerotow.create(tow, @ref)
          {:ok, 1} = Aerotow.run(tow, @ref, "CREATE (:N)")
          :ok = Aerotow.land(tow, @ref)
          {:ok, _} = Aerotow.scan(tow)

          assert {:error, reason} = Aerotow.add_store(tow, "worse", "s3://graphs/x", bad)

          status = :sys.get_status(instance!(tow).server)
          spec = Aerotow.child_spec(name: tow, dir: dir, stores: [{"bad", "s3://graphs/b", bad}])
          refute inspect(spec, limit: :infinity) =~ wrong

          for shown <- [inspect(stores), inspect(reason), inspect(status, limit: :infinity)] do
            refute shown =~ secret
            refute shown =~ wrong
          end

          FakeS3.fail(fake, 100)
          _ = Aerotow.add_store(tow, "failing", "s3://graphs/y", s3)
        end)

      refute log =~ secret
      refute log =~ wrong
      events = collected()
      assert events != []
      refute inspect(events, limit: :infinity) =~ secret
      refute inspect(events, limit: :infinity) =~ wrong
    end
  end

  def telemetry_events do
    for event <- [:launch, :land, :sync, :scan, :statement],
        phase <- [:start, :stop, :exception],
        do: [:aerotow, event, phase]
  end

  @doc false
  def collect(event, measurements, metadata, pid),
    do: send(pid, {:collected, event, measurements, metadata})

  defp collected(acc \\ []) do
    receive do
      {:collected, _, _, _} = event -> collected([event | acc])
    after
      0 -> acc
    end
  end

  describe "12: the instance stops cleanly" do
    test "stopping lands every flight, closes the catalog and frees the directory at once", %{
      tmp_dir: dir
    } do
      stores = [{"store", Path.join(dir, "store")}]
      a_dir = Path.join(dir, "a")
      a = tow(a_dir, stores: stores, default_store: "store")
      {:ok, _} = Aerotow.create(a, @ref)
      {:ok, _} = Aerotow.create(a, "g/two")
      {:ok, 1} = Aerotow.run(a, @ref, "CREATE (:N {n: 1})")
      {:ok, store} = Server.store(instance!(a), "store")

      :ok = stop_supervised!(a)
      assert Instance.fetch(a) == {:error, :not_running}
      assert {:ok, %Lease{landed: true}} = Lease.current(store, @ref)
      assert {:ok, %Lease{landed: true}} = Lease.current(store, "g/two")
      assert Path.wildcard(Path.join([a_dir, "flights", "**", "*.gldb"])) == []

      again = tow(a_dir, stores: stores)
      assert rows(Aerotow.query(again, @ref, "MATCH (n:N) RETURN n.n")) == [[1]]
    end
  end

  describe "working copies left behind" do
    test "what is under flights/ at start is moved whole to orphans/ before the first launch", %{
      tmp_dir: dir
    } do
      a_dir = Path.join(dir, "a")
      {:ok, store} = Store.new("store", Path.join(dir, "store"))
      left = Path.join([a_dir, "flights", "store", "g", "left.gldb"])
      File.mkdir_p!(Path.dirname(left))
      File.write!(left, "log that never shipped")
      :ok = Copy.write_marker(left, store, "g/left", 3)
      File.write!(Path.join([a_dir, "flights", "stray"]), "something else")

      listen([[:aerotow, :flight, :orphaned]])
      _tow = tow(a_dir, stores: [{"store", Path.join(dir, "store")}])

      kept = Path.join([a_dir, "orphans", "store", "g", "left.3.gldb"])
      assert File.read!(kept) == "log that never shipped"
      assert {:ok, %{ref: "g/left", flight: 3}} = Copy.read_marker(kept)
      refute File.exists?(Path.join(a_dir, "flights"))
      assert [stray] = Path.wildcard(Path.join([a_dir, "orphans", "left-*", "stray"]))
      assert File.read!(stray) == "something else"

      assert_received {:telemetry, [:aerotow, :flight, :orphaned], _,
                       %{ref: "g/left", path: ^kept}}
    end

    test "a launch that finds a copy where its own goes sets it aside and launches", %{
      tmp_dir: dir
    } do
      tow =
        tow(Path.join(dir, "a"),
          stores: [{"store", Path.join(dir, "store")}],
          default_store: "store"
        )

      {:ok, _} = Aerotow.create(tow, @ref)
      {:ok, 1} = Aerotow.run(tow, @ref, "CREATE (:N {n: 1})")
      :ok = Aerotow.land(tow, @ref)

      instance = instance!(tow)
      {:ok, store} = Server.store(instance, "store")
      path = Copy.path(instance, store, @ref)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "left behind")
      :ok = Copy.write_marker(path, store, @ref, 1)

      assert rows(Aerotow.query(tow, @ref, "MATCH (n:N) RETURN n.n")) == [[1]]
      orphan = Path.join([instance.dir, "orphans", "store", @ref <> ".1.gldb"])
      assert File.read!(orphan) == "left behind"
    end
  end

  describe "8: purge" do
    test "a purge holds the glider's flight until its record is deleted last: nobody takes it in between",
         %{tmp_dir: dir} do
      {a, ctl, path} = stalled_tow(dir)
      {:ok, _} = Aerotow.create(a, @ref, store: "store")
      {:ok, 1} = Aerotow.run(a, @ref, "CREATE (:N)")
      :ok = Aerotow.land(a, @ref)

      b = tow(Path.join(dir, "b"), stores: [{"store", path}])
      {:ok, _} = Aerotow.scan(b, "store")
      assert {:ok, %{ref: @ref}} = Aerotow.card(b, @ref)

      StallStore.set(ctl, :delete, :block)
      purge = Task.async(fn -> Aerotow.delete(a, @ref, purge: true) end)
      assert_receive {:stalled, :delete, _key}, 10_000

      a_id = instance!(a).id
      assert {:error, {:aloft_elsewhere, %{holder: ^a_id}}} = Aerotow.query(b, @ref, "STATS")
      assert Aerotow.query(a, @ref, "STATS") == {:error, :purging}

      StallStore.release(ctl)
      assert Task.await(purge, 30_000) == :ok
      assert Aerotow.query(b, @ref, "STATS") == {:error, :not_found}
      assert Aerotow.query(a, @ref, "STATS") == {:error, :not_found}
      {:ok, store} = Store.new("plain", path)
      assert {:ok, %{objects: []}} = Store.list(store, "gliders/")
    end
  end

  describe "13: telemetry" do
    test "statements are spans with ref, op and where", %{tmp_dir: dir} do
      tow = tow(dir, stores: [{"store", Path.join(dir, "store")}], default_store: "store")
      {:ok, _} = Aerotow.create(tow, @ref)
      listen([[:aerotow, :statement, :start], [:aerotow, :statement, :stop]])

      {:ok, _} = Aerotow.query(tow, @ref, "STATS")

      assert_received {:telemetry, [:aerotow, :statement, :start], _,
                       %{ref: @ref, op: :query, where: :here}}

      assert_received {:telemetry, [:aerotow, :statement, :stop], %{duration: _},
                       %{ref: @ref, op: :query, where: :here, result: :ok}}

      {:ok, _} = Aerotow.run(tow, @ref, "CREATE (:N)")
      assert_received {:telemetry, [:aerotow, :statement, :stop], _, %{op: :run, where: :here}}
    end
  end

  describe "14: fifty gliders, two instances" do
    @tag timeout: 600_000
    test "created on one, scanned on the other, queried from the other after the first lands them",
         %{tmp_dir: dir} do
      {_fake, s3} = s3()
      stores = [{"assets", "s3://graphs/gliders", s3}]
      a = tow(Path.join(dir, "a"), stores: stores, default_store: "assets")
      b = tow(Path.join(dir, "b"), stores: stores, default_store: "assets")
      refs = for i <- 1..50, do: "many/g#{i}"
      started = System.monotonic_time(:millisecond)

      refs
      |> Task.async_stream(
        fn ref ->
          {:ok, _} = Aerotow.create(a, ref, tags: ["many"])

          {:ok, 5} =
            Aerotow.write_batch(a, ref, for(n <- 1..5, do: {"CREATE (:N {n: $n})", %{n: n}}))

          :ok
        end,
        max_concurrency: 50,
        timeout: :infinity
      )
      |> Enum.each(&assert(&1 == {:ok, :ok}))

      created = System.monotonic_time(:millisecond)
      assert {:ok, %{seen: 50, added: 50}} = Aerotow.scan(b, "assets")
      scanned = System.monotonic_time(:millisecond)

      refs
      |> Task.async_stream(&Aerotow.land(a, &1), max_concurrency: 50, timeout: :infinity)
      |> Enum.each(&assert(&1 == {:ok, :ok}))

      landed = System.monotonic_time(:millisecond)

      counts =
        refs
        |> Task.async_stream(
          &rows(Aerotow.query(b, &1, "MATCH (n:N) RETURN count(n)")),
          max_concurrency: 50,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, rows} -> rows end)

      done = System.monotonic_time(:millisecond)
      assert Enum.all?(counts, &(&1 == [[5]]))
      assert {:ok, %{gliders: gliders}} = Aerotow.gliders(b, tag: "many", limit: 100)
      assert length(gliders) == 50

      IO.puts(
        "\nfifty gliders, two instances: created and written on A in #{created - started} ms; " <>
          "scanned on B in #{scanned - created} ms; landed on A in #{landed - scanned} ms; " <>
          "launched and queried on B in #{done - landed} ms"
      )
    end
  end
end
