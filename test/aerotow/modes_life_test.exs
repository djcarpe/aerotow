defmodule Aerotow.ModesLifeTest do
  # Each way of holding a glider's pages, the whole life, on each kind of
  # object store: created, written, shipped, landed, launched again here
  # and on another instance, read, landed. Not async: the S3 fake and the
  # stores make atoms, which Aerotow.CardTest counts.
  use ExUnit.Case,
    async: false,
    parameterize:
      for(kind <- [:dir, :s3], mode <- ["memory", "disk", "hot"], do: %{kind: kind, mode: mode})

  import Aerotow.TowCase
  import Aerotow.FlightCase, only: [files_under: 1]

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ref "engineering/code"
  @hot 1_048_576

  defp ns(tow) do
    {:ok, %{rows: rows}} = Aerotow.query(tow, @ref, "MATCH (x:N) RETURN x.n ORDER BY x.n")
    Enum.map(rows, fn [n] -> n end)
  end

  defp write(tow, n), do: Aerotow.run(tow, @ref, "CREATE (:N {n: $n})", %{n: n})

  defp card_opts("memory"), do: [mode: "memory"]
  defp card_opts("disk"), do: [mode: "disk"]
  defp card_opts("hot"), do: [mode: "disk", hot: @hot]

  defp flies("memory"), do: "memory"
  defp flies(_disk), do: "disk"

  defp store(%{kind: :dir, tmp_dir: dir}), do: {"s", Path.join(dir, "store"), []}

  defp store(%{kind: :s3}) do
    {_fake, opts} = s3()
    {"s", "s3://graphs/gliders", opts}
  end

  # What this flight is, as aloft/1 says, after it has been checked: the
  # mode it flies in, its hot set when it has one, and nothing of a memory
  # flight's on disk.
  defp aloft(tow, dir, mode) do
    assert {:ok, [info]} = Aerotow.aloft(tow)
    assert %{ref: @ref, state: :aloft} = info
    assert info.mode == flies(mode)
    databases = dir |> Path.join("flights") |> files_under()

    case mode do
      "memory" ->
        assert databases == []
        assert info.hot == nil

      "disk" ->
        assert Enum.any?(databases, &String.ends_with?(&1, ".gldb"))
        assert info.hot == nil

      "hot" ->
        assert Enum.any?(databases, &String.ends_with?(&1, ".gldb"))
        assert %{hot_capacity: capacity} = info.hot
        assert capacity > 0
    end

    info
  end

  test "created, shipped, landed, launched here and on another instance: every write is there each time",
       %{tmp_dir: dir, mode: mode} = ctx do
    store = store(ctx)
    a_dir = Path.join(dir, "a")
    b_dir = Path.join(dir, "b")
    a = tow(a_dir, stores: [store], default_store: "s")
    b = tow(b_dir, stores: [store], default_store: "s")

    {:ok, _card} = Aerotow.create(a, @ref, card_opts(mode))
    aloft(a, a_dir, mode)
    for n <- 1..3, do: {:ok, 1} = write(a, n)
    assert {:ok, %{generation: generation}} = Aerotow.sync(a, @ref)
    assert is_binary(generation)
    :ok = Aerotow.land(a, @ref)
    assert files_under(Path.join(a_dir, "flights")) == []

    :ok = Aerotow.launch(a, @ref)
    aloft(a, a_dir, mode)
    assert ns(a) == [1, 2, 3]
    {:ok, 1} = write(a, 4)
    :ok = Aerotow.land(a, @ref)

    {:ok, _} = Aerotow.scan(b, "s")
    :ok = Aerotow.launch(b, @ref)
    aloft(b, b_dir, mode)
    assert ns(b) == [1, 2, 3, 4]
    {:ok, 1} = write(b, 5)
    :ok = Aerotow.land(b, @ref)

    :ok = Aerotow.launch(a, @ref)
    aloft(a, a_dir, mode)
    assert ns(a) == [1, 2, 3, 4, 5]
    :ok = Aerotow.land(a, @ref)
    assert files_under(Path.join(a_dir, "flights")) == []
    assert files_under(Path.join(b_dir, "flights")) == []
    assert {:ok, %{nodes: 5}} = Aerotow.card(a, @ref)
  end
end
