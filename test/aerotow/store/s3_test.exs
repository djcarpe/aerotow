defmodule Aerotow.Store.S3Test do
  # Not async: every test starts a server, the first ones load code, and the
  # module raises the log level for the whole VM while it runs (R4).
  use ExUnit.Case, async: false

  import Aerotow.ObjectsCase

  alias Aerotow.FakeS3
  alias Aerotow.Store
  alias Aerotow.Store.{Layout, S3}

  @bucket "graphs"
  @secret FakeS3.credentials().secret_access_key

  # ------------------------------------------------------------------ the log (R4)

  # Every log event of every process, at every level, while this module
  # runs, is kept, and each test ends by checking that the secret is in none
  # of them.
  setup_all do
    table = :ets.new(:s3_test_log, [:duplicate_bag, :public])
    %{level: level} = :logger.get_primary_config()
    :ok = :logger.set_primary_config(:level, :all)

    console =
      case :logger.get_handler_config(:default) do
        {:ok, %{level: console}} ->
          :ok = :logger.set_handler_config(:default, :level, level)
          console

        _ ->
          nil
      end

    :ok =
      :logger.add_handler(:aerotow_s3_test, __MODULE__, %{level: :all, config: %{table: table}})

    on_exit(fn ->
      :logger.remove_handler(:aerotow_s3_test)
      :logger.set_primary_config(:level, level)
      if console, do: :logger.set_handler_config(:default, :level, console)
    end)

    %{log: table}
  end

  @doc false
  def log(event, %{config: %{table: table}}) do
    :ets.insert(table, {inspect(event, limit: :infinity, printable_limit: :infinity)})
  rescue
    _ -> :ok
  end

  setup %{log: table} do
    on_exit(fn ->
      leaked = for {line} <- :ets.tab2list(table), String.contains?(line, @secret), do: line
      if leaked != [], do: raise("R4: the secret is in a log line: #{hd(leaked)}")
    end)
  end

  # ------------------------------------------------------------------ helpers

  defp fake(opts \\ []) do
    start_supervised!({FakeS3, Keyword.put_new(opts, :buckets, [@bucket, "other"])},
      id: make_ref()
    )
  end

  defp opts(fake, extra) do
    creds = FakeS3.credentials()

    Keyword.merge(
      [
        endpoint: FakeS3.endpoint(fake),
        access_key_id: creds.access_key_id,
        secret_access_key: creds.secret_access_key
      ],
      extra
    )
  end

  defp store(fake, url \\ "s3://#{@bucket}/gliders", extra \\ []) do
    {:ok, store} = Store.new("assets", url, opts(fake, extra))
    store
  end

  defp config(fake, url \\ "s3://#{@bucket}/gliders", extra \\ []) do
    {:ok, config} = S3.init("assets", url, opts(fake, extra))
    config
  end

  defp keys(store, prefix \\ "", opts \\ []) do
    {:ok, %{objects: objects}} = Store.list(store, prefix, opts)
    Enum.map(objects, & &1.key)
  end

  defp count(fake, method) do
    fake |> FakeS3.requests() |> Enum.count(&(&1.method == method))
  end

  # A port nothing listens on.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Every operation of the store's module, as {name, result}.
  defp every_operation(config) do
    [
      get: S3.get(config, "t/k"),
      put: S3.put(config, "t/k", "x", []),
      exclusive_put: S3.put(config, "t/k", "x", exclusive: true),
      delete: S3.delete(config, "t/k"),
      list: S3.list(config, "t/", []),
      list_with_delimiter: S3.list(config, "t/", delimiter: true),
      probe: S3.probe(config)
    ]
  end

  defp assert_errors(results, pattern) do
    for {op, result} <- results do
      assert {:error, reason} = result, "#{op} gave #{inspect(result)}"
      assert is_binary(reason), "#{op} gave #{inspect(result)}"
      assert reason =~ pattern, "#{op}: #{reason}"
      refute reason =~ @secret
    end
  end

  # ------------------------------------------------------------------ conformance

  objects_conformance(fn _context -> store(fake()) end)

  # ------------------------------------------------------------------ init

  describe "init/3" do
    test "takes s3://bucket and s3://bucket/prefix, with or without a trailing slash" do
      creds = FakeS3.credentials() |> Map.to_list()

      assert {:ok, %{bucket: "graphs", prefix: ""}} = S3.init("s", "s3://graphs", creds)
      assert {:ok, %{bucket: "graphs", prefix: ""}} = S3.init("s", "s3://graphs/", creds)
      assert {:ok, %{prefix: "a/b"}} = S3.init("s", "s3://graphs/a/b/", creds)
      assert {:ok, %{prefix: "a.b-c_d"}} = S3.init("s", "s3://my.bucket-1/a.b-c_d", creds)
    end

    test "refuses a url that is not s3://bucket[/prefix], and a bucket name that is not one" do
      creds = FakeS3.credentials() |> Map.to_list()

      for url <- [
            "s3:/graphs",
            "http://graphs/x",
            "graphs/x",
            "s3://",
            "s3:///x",
            "s3://ab",
            "s3://" <> String.duplicate("a", 64),
            "s3://Graphs",
            "s3://gra_phs",
            "s3://-graphs",
            "s3://graphs-",
            "s3://gra..phs",
            "s3://gra.-phs",
            "s3://192.168.1.10",
            "s3://xn--graphs",
            "s3://graphs-s3alias",
            "s3://graphs/a//b",
            "s3://graphs/../x",
            "s3://graphs/a/./b",
            "s3://graphs/a?versionId=1",
            "s3://graphs/a#b",
            "s3://key:#{@secret}@graphs/a"
          ] do
        assert {:error, reason} = S3.init("s", url, creds), url
        assert is_binary(reason)
        refute reason =~ @secret
      end

      assert {:error, _} = S3.init("s", nil, creds)
    end

    test "refuses missing credentials, from the options and from the environment" do
      saved =
        for name <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY), do: {name, System.get_env(name)}

      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      on_exit(fn ->
        for {name, value} <- saved, value != nil, do: System.put_env(name, value)
      end)

      assert {:error, reason} = S3.init("s", "s3://graphs", [])
      assert reason =~ "access_key_id"
      assert {:error, reason} = S3.init("s", "s3://graphs", access_key_id: "AKIA")
      assert reason =~ "secret_access_key"
      assert {:error, reason} = S3.init("s", "s3://graphs", secret_access_key: @secret)
      refute reason =~ @secret
      assert {:error, _} = S3.init("s", "s3://graphs", access_key_id: "", secret_access_key: "x")

      assert {:error, reason} = Store.new("s", "s3://graphs/x", secret_access_key: @secret)
      assert reason =~ "access_key_id"
      refute reason =~ @secret

      System.put_env("AWS_ACCESS_KEY_ID", "AKIAFROMENV")
      System.put_env("AWS_SECRET_ACCESS_KEY", @secret)
      assert {:ok, config} = S3.init("s", "s3://graphs", [])
      assert {_url, opts} = S3.replica(config, "x")
      assert opts[:access_key_id] == "AKIAFROMENV"
      assert opts[:secret_access_key] == @secret
    end

    test "refuses an endpoint, region, path_style or timeout that is not one" do
      creds = FakeS3.credentials() |> Map.to_list()

      for bad <- [
            endpoint: "minio:9000",
            endpoint: "ftp://minio",
            endpoint: "http://minio:9000/base",
            endpoint: "http://key:#{@secret}@minio:9000",
            endpoint: "http://minio?x=1",
            endpoint: 9000,
            region: "US East",
            region: :us_east_1,
            path_style: "yes",
            receive_timeout: 0,
            receive_timeout: "1s",
            timeout: -1
          ] do
        assert {:error, reason} = S3.init("s", "s3://graphs", [bad | creds]), inspect(bad)
        refute reason =~ @secret
      end
    end

    test "is path-style with an endpoint and virtual-hosted on AWS, unless told otherwise" do
      creds = FakeS3.credentials() |> Map.to_list()

      assert {:ok, %{path_style: true, base: "http://minio:9000"}} =
               S3.init("s", "s3://graphs", [endpoint: "http://minio:9000/"] ++ creds)

      assert {:ok, %{path_style: false, base: "http://graphs.minio:9000"}} =
               S3.init(
                 "s",
                 "s3://graphs",
                 [endpoint: "http://minio:9000", path_style: false] ++ creds
               )

      assert {:ok, %{path_style: false, base: "https://graphs.s3.eu-west-2.amazonaws.com"}} =
               S3.init("s", "s3://graphs", [region: "eu-west-2"] ++ creds)

      assert {:ok, %{path_style: true, base: "https://s3.us-east-1.amazonaws.com"}} =
               S3.init("s", "s3://graphs", [path_style: true] ++ creds)
    end
  end

  # ------------------------------------------------------------------ replica

  describe "replica/2" do
    test "is the bucket, the store's prefix and the replica's prefix, with what glider needs" do
      creds = FakeS3.credentials()
      prefix = Layout.flight_data("eng/code", 1)

      config = config(fake())

      assert {url, opts} = S3.replica(config, prefix)
      assert url == "s3://#{@bucket}/gliders/#{prefix}"

      assert opts == [
               endpoint: config.endpoint,
               region: "us-east-1",
               access_key_id: creds.access_key_id,
               secret_access_key: creds.secret_access_key
             ]

      {:ok, bare} = S3.init("s", "s3://graphs", Map.to_list(creds))
      assert {"s3://graphs/x/y", opts} = S3.replica(bare, "x/y")
      refute Keyword.has_key?(opts, :endpoint)

      assert_raise ArgumentError, fn -> S3.replica(config, "../x") end
    end

    @tag :tmp_dir
    @tag timeout: 120_000
    test "glider ships into it where the layout says, and a listing of the glider's flights shows only the flight's directory",
         %{tmp_dir: dir} do
      fake = fake()
      store = store(fake)
      ref = "eng/code"
      data = Layout.flight_data(ref, 1)
      path = Path.join(dir, "work.gldb")
      {:ok, db} = Glider.open(path)
      {:ok, _} = Glider.run(db, ~S|CREATE (:Job {name:"build"})|)

      {url, opts} = Store.replica(store, data)
      task = Task.async(fn -> Glider.Replication.sync(path, url, [db: db] ++ opts) end)
      assert {:ok, {:ok, %{bases_uploaded: 1}}} = Task.yield(task, 60_000) || Task.shutdown(task)
      Glider.close(db)

      shipped = keys(store, data <> "/")
      assert shipped != []

      for key <- shipped do
        assert key =~
                 ~r"\Agliders/eng/code/_flights/0000000001/[0-9a-f]+/(base/[0-9a-f]+/.+|segments/.+)\z"
      end

      assert Enum.any?(shipped, &(&1 =~ ~r"/base/[0-9a-f]+/base\.json\z"))

      # In the bucket itself, under the store's prefix and nowhere else.
      raw = FakeS3.keys(fake, @bucket)
      assert Enum.all?(raw, &String.starts_with?(&1, "gliders/"))
      for key <- shipped, do: assert(("gliders/" <> key) in raw)

      assert {:ok, %{objects: [], prefixes: [prefix]}} =
               Store.list(store, Layout.flights_prefix(ref), delimiter: true)

      assert prefix == data <> "/"
    end
  end

  # ------------------------------------------------------------------ listings

  describe "listings" do
    test "are complete across pages, in order, with and without a delimiter" do
      fake = fake()
      store = store(fake)

      keys =
        for i <- 1..100 do
          name = i |> Integer.to_string() |> String.pad_leading(3, "0")
          if rem(i, 3) == 0, do: "p/k#{name}", else: "p/d#{rem(i, 9)}/k#{name}"
        end

      for key <- keys, do: :ok = Store.put(store, key, key)
      FakeS3.page_size(fake, 7)
      FakeS3.clear_requests(fake)

      assert {:ok, %{objects: objects, prefixes: []}} = Store.list(store, "p/")
      assert Enum.map(objects, & &1.key) == Enum.sort(keys)
      assert length(objects) == 100
      assert count(fake, "GET") == 15

      assert {:ok, %{objects: objects, prefixes: prefixes}} =
               Store.list(store, "p/", delimiter: true)

      shallow = for key <- keys, not String.contains?(key, "/d"), do: key
      assert Enum.map(objects, & &1.key) == Enum.sort(shallow)
      assert prefixes == for(d <- [1, 2, 4, 5, 7, 8], do: "p/d#{d}/")
    end

    test "never give a common prefix twice, even when it spans pages" do
      fake = fake()
      store = store(fake)

      # Each directory holds more keys than a page.
      keys = for d <- 1..9, i <- 1..12, do: "q/d#{d}/k#{i}"
      for key <- keys, do: :ok = Store.put(store, key, "x")
      FakeS3.page_size(fake, 2)
      FakeS3.clear_requests(fake)

      assert {:ok, %{objects: [], prefixes: prefixes}} = Store.list(store, "q/", delimiter: true)
      assert prefixes == for(d <- 1..9, do: "q/d#{d}/")
      assert count(fake, "GET") == 5
    end

    test "decode the entities S3 escapes keys with" do
      fake = fake()
      store = store(fake)
      keys = ["e/a&b", "e/<tag>", "e/\"quoted\"", "e/it's", "e/&amp;"]
      for key <- keys, do: :ok = Store.put(store, key, key)
      assert keys(store, "e/") == Enum.sort(keys)
    end
  end

  describe "keys" do
    test "every character a layout key, a glider replica key, or a key given directly holds survives a round trip" do
      fake = fake()
      store = store(fake)

      keys = [
        Layout.card("a0/b.c_d-e/f"),
        Layout.flight_record("eng/code", 9_999_999_999),
        Layout.flight_data("eng/code", 1) <>
          "/96348bfb24205901aabbccddeeff0011/base/0000000000001000/data/0001.seg",
        Layout.flight_data("eng/code", 1) <>
          "/96348bfb24205901aabbccddeeff0011/segments/00000000000000ff-1763400000.seg",
        "k/a+b",
        "k/a b",
        "k/100%",
        "k/%2F",
        "k/a%20b",
        "k/+ %",
        "k/~!*'();:@&=$,?#[]",
        "k/é/日本/🛩",
        "k/tab nbsp"
      ]

      for key <- keys do
        assert :ok = Store.put(store, key, "body of " <> key), key
        assert {:ok, "body of " <> ^key} = Store.get(store, key)
      end

      assert keys(store) |> Enum.reject(&(&1 == "aerotow.json")) == Enum.sort(keys)

      # The bucket holds the keys themselves, not an encoding of them.
      assert FakeS3.keys(fake, @bucket) -- ["gliders/aerotow.json"] ==
               Enum.sort(Enum.map(keys, &("gliders/" <> &1)))

      for key <- keys, do: assert(:ok = Store.delete(store, key))
      assert keys(store) == ["aerotow.json"]
    end
  end

  # ------------------------------------------------------------------ probe

  describe "probe/1" do
    test "is cas: true against the fake as built, and leaves nothing behind" do
      fake = fake()
      config = config(fake)
      assert {:ok, %{cas: true}} = S3.probe(config)
      assert FakeS3.keys(fake, @bucket) == []
      assert count(fake, "PUT") >= 2 + 2 * 8
    end

    test "is cas: false where If-None-Match is ignored, and Store.new/3 says so" do
      fake = fake()
      FakeS3.conditional(fake, :ignore)
      assert {:ok, %{cas: false}} = S3.probe(config(fake))
      assert FakeS3.keys(fake, @bucket) == []

      assert %Store{cas: false, id: id} = store(fake)
      assert id =~ ~r/\A[0-9a-f]{32}\z/
      assert FakeS3.keys(fake, @bucket) == ["gliders/aerotow.json"]
    end

    test "is cas: false where If-None-Match is refused, and an exclusive put says why" do
      fake = fake()
      FakeS3.conditional(fake, :refuse)
      config = config(fake)
      assert {:ok, %{cas: false}} = S3.probe(config)
      assert FakeS3.keys(fake, @bucket) == []
      assert %Store{cas: false} = store(fake)

      assert {:error, reason} = S3.put(config, "t/k", "x", exclusive: true)
      assert reason =~ "If-None-Match"
    end
  end

  # ------------------------------------------------------------------ prefixes

  describe "the store's prefix" do
    test "confines it: two stores on one bucket never see each other's objects" do
      fake = fake()
      west = store(fake, "s3://#{@bucket}/west")
      western = store(fake, "s3://#{@bucket}/west-2")

      assert west.id != western.id

      for {store, name} <- [{west, "west"}, {western, "western"}] do
        :ok = Store.put(store, "t/a", name)
        :ok = Store.put(store, "t/#{name}", name)
      end

      assert {:ok, "west"} = Store.get(west, "t/a")
      assert {:ok, "western"} = Store.get(western, "t/a")
      assert keys(west) == ["aerotow.json", "t/a", "t/west"]
      assert keys(western) == ["aerotow.json", "t/a", "t/western"]

      assert {:ok, %{prefixes: ["t/"], objects: [%{key: "aerotow.json"}]}} =
               Store.list(west, "", delimiter: true)

      assert {:error, :exists} = Store.put(west, "t/west", "again", exclusive: true)
      assert :ok = Store.put(western, "t/west", "mine", exclusive: true)
      :ok = Store.delete(west, "t/a")
      assert {:ok, "western"} = Store.get(western, "t/a")
    end

    test "may be empty, which is the whole bucket" do
      fake = fake()
      store = store(fake, "s3://other")
      assert {:ok, %{config: %{prefix: ""}}} = {:ok, store}
      :ok = Store.put(store, "cards/a.json", "x")
      assert {:ok, "x"} = Store.get(store, "cards/a.json")
      assert keys(store) == ["aerotow.json", "cards/a.json"]
      assert FakeS3.keys(fake, "other") == ["aerotow.json", "cards/a.json"]
      assert {"s3://other/cards", _} = Store.replica(store, "cards")
    end
  end

  # ------------------------------------------------------------------ errors

  describe "errors are answers" do
    test "a 500 is retried a bounded number of times, then is an error from every operation" do
      fake = fake()
      config = config(fake)

      FakeS3.fail(fake, 2)
      assert {:error, :not_found} = S3.get(config, "t/k")
      assert count(fake, "GET") == 3

      FakeS3.fail(fake, 1)
      assert :ok = S3.put(config, "t/plain", "x", [])
      assert {:ok, "x"} = S3.get(config, "t/plain")

      FakeS3.fail(fake, 1)
      assert :ok = S3.delete(config, "t/plain")

      FakeS3.fail(fake, 1_000)
      FakeS3.clear_requests(fake)
      assert {:error, reason} = S3.get(config, "t/k")
      assert reason =~ "500 InternalError"
      assert count(fake, "GET") == 3

      assert_errors(every_operation(config), "500")
    end

    test "a stalled bucket is an error within the operation's time" do
      fake = fake()
      config = config(fake, "s3://#{@bucket}/gliders", receive_timeout: 200, timeout: 1_000)
      FakeS3.stall(fake, 1_000, 3_000)

      for {op, fun} <- [
            get: fn -> S3.get(config, "t/k") end,
            exclusive_put: fn -> S3.put(config, "t/k", "x", exclusive: true) end,
            list: fn -> S3.list(config, "t/", []) end
          ] do
        started = System.monotonic_time(:millisecond)
        assert {:error, reason} = fun.(), "#{op}"
        elapsed = System.monotonic_time(:millisecond) - started
        assert reason =~ "no answer within", "#{op}: #{reason}"
        assert elapsed < 1_500, "#{op} took #{elapsed} ms"
      end

      assert_errors(every_operation(config), "no answer within")
    end

    test "a refused connection is an error from every operation" do
      creds = FakeS3.credentials() |> Map.to_list()

      {:ok, config} =
        S3.init("s", "s3://graphs/x", [endpoint: "http://127.0.0.1:#{closed_port()}"] ++ creds)

      assert_errors(every_operation(config), "refused")

      assert {:error, reason} =
               Store.new("s", "s3://graphs/x", [endpoint: config.endpoint] ++ creds)

      assert reason =~ "refused"
    end

    test "a wrong secret or access key is a 403 from every operation" do
      fake = fake()

      wrong_secret = config(fake, "s3://#{@bucket}/x", secret_access_key: "not-the-secret")
      assert_errors(every_operation(wrong_secret), "403 SignatureDoesNotMatch")

      wrong_key = config(fake, "s3://#{@bucket}/x", access_key_id: "AKIANOBODY")
      assert_errors(every_operation(wrong_key), "403 InvalidAccessKeyId")
      assert FakeS3.requests(fake) == []
    end

    test "a request with no signature is refused by the fake" do
      fake = fake()
      assert {:ok, %{status: 403}} = Req.get(FakeS3.endpoint(fake) <> "/graphs/k", retry: false)
      assert FakeS3.requests(fake) == []
    end

    test "a missing bucket is an error from every operation, naming the bucket" do
      fake = fake()
      config = config(fake, "s3://nowhere/x")
      assert_errors(every_operation(config), "the bucket nowhere does not exist")

      assert {:error, reason} = Store.new("s", "s3://nowhere/x", opts(fake, []))
      assert reason =~ "the bucket nowhere does not exist"
    end
  end

  # ------------------------------------------------------------------ exclusive puts

  describe "an exclusive put whose answer was lost" do
    test "is :ok when its object was written, without being put again" do
      fake = fake()
      config = config(fake)
      FakeS3.lose(fake, 1)

      assert :ok = S3.put(config, "t/lost", "mine", exclusive: true)
      assert {:ok, "mine"} = S3.get(config, "t/lost")
      assert count(fake, "PUT") == 1
      assert count(fake, "HEAD") == 1
    end

    test "is :exists when the object there is somebody else's" do
      fake = fake()
      config = config(fake)
      :ok = S3.put(config, "t/taken", "theirs", exclusive: true)
      FakeS3.clear_requests(fake)
      FakeS3.fail(fake, 1)

      assert {:error, :exists} = S3.put(config, "t/taken", "mine", exclusive: true)
      assert {:ok, "theirs"} = S3.get(config, "t/taken")
      assert count(fake, "PUT") == 1
    end

    test "is put again when nothing was written, and then wins" do
      fake = fake()
      config = config(fake)
      FakeS3.fail(fake, 1)

      assert :ok = S3.put(config, "t/fresh", "mine", exclusive: true)
      assert {:ok, "mine"} = S3.get(config, "t/fresh")
      assert count(fake, "PUT") == 2
      assert count(fake, "HEAD") == 1
    end

    test "a 409 conflict is not a write: the key is looked at, and the put tried again" do
      fake = fake()
      config = config(fake)
      FakeS3.conflict(fake, 1)

      assert :ok = S3.put(config, "t/conflict", "mine", exclusive: true)
      assert {:ok, "mine"} = S3.get(config, "t/conflict")
      assert count(fake, "PUT") == 2

      FakeS3.conflict(fake, 1)
      assert {:error, :exists} = S3.put(config, "t/conflict", "again", exclusive: true)
      assert {:ok, "mine"} = S3.get(config, "t/conflict")
    end

    test "is an error saying so when the bucket cannot tell either" do
      fake = fake()
      config = config(fake)
      FakeS3.fail(fake, 1_000)

      assert {:error, reason} = S3.put(config, "t/unknown", "mine", exclusive: true)
      assert reason =~ "whether it was written is not known"
    end

    test "R7: of many writers racing while answers are lost, exactly one gets :ok and the object is its own" do
      fake = fake()
      config = config(fake)

      for round <- 1..20 do
        key = "race/#{round}"
        FakeS3.lose(fake, 3)
        test = self()

        for i <- 1..8 do
          spawn_link(fn ->
            send(test, {round, i, S3.put(config, key, "writer #{i}", exclusive: true)})
          end)
        end

        results =
          for i <- 1..8 do
            assert_receive {^round, ^i, result}, 30_000
            {i, result}
          end

        assert [{winner, :ok}] = Enum.filter(results, &match?({_, :ok}, &1)), inspect(results)
        assert Enum.count(results, &match?({_, {:error, :exists}}, &1)) == 7
        assert {:ok, "writer #{winner}"} == S3.get(config, key)
      end
    end
  end

  # ------------------------------------------------------------------ credentials

  describe "R4" do
    test "R4: no credential in inspect/1 of the store or its config, in public/1, or in a reason",
         %{log: log} do
      # The capture that every test ends by searching does see the log.
      require Logger
      Logger.debug("aerotow s3 log capture check")

      assert Enum.any?(:ets.tab2list(log), fn {line} -> line =~ "aerotow s3 log capture check" end)

      fake = fake()
      store = store(fake)

      for shown <- [inspect(store), inspect(store.config), inspect(Store.public(store))] do
        refute shown =~ @secret
      end

      config = config(fake, "s3://nowhere/x", receive_timeout: 100, timeout: 300)
      FakeS3.stall(fake, 5, 1_000)
      assert_errors(every_operation(config), "")

      assert_errors(
        every_operation(config(fake, "s3://#{@bucket}/x", secret_access_key: "no")),
        ""
      )
    end
  end
end
