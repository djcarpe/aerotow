defmodule Aerotow.Store.LayoutTest do
  use ExUnit.Case, async: true

  alias Aerotow.Store.Layout

  doctest Aerotow.Store.Layout

  test "the gliders a and a/b share no key" do
    a = [
      Layout.card("a"),
      Layout.flights_prefix("a"),
      Layout.flight_record("a", 1),
      Layout.flight_data("a", 1) <> "/"
    ]

    ab = [
      Layout.card("a/b"),
      Layout.flights_prefix("a/b"),
      Layout.flight_record("a/b", 1),
      Layout.flight_data("a/b", 1) <> "/"
    ]

    for x <- a, y <- ab do
      refute String.starts_with?(x, y), "#{x} is under #{y}"
      refute String.starts_with?(y, x), "#{y} is under #{x}"
    end
  end

  test "a card's key gives its ref back, and only a card's" do
    for ref <- ~w(a a/b acme/eng/v1.2/code x.json) do
      assert Layout.ref_of_card(Layout.card(ref)) == {:ok, ref}
    end

    for key <- [
          "cards/",
          "cards/.json",
          "cards/a",
          "cards/A.json",
          "cards/a/../b.json",
          "gliders/a.json",
          "a.json"
        ] do
      assert Layout.ref_of_card(key) == :error, key
    end
  end

  test "flight numbers sort as their names do" do
    names = for n <- [1, 2, 10, 99, 100, 9_999_999_999], do: Layout.flight_record("a", n)
    assert names == Enum.sort(names)
    assert Layout.max_flight() == 9_999_999_999
  end

  test "a record's key gives its flight back, for that glider only" do
    assert Layout.flight_of_record("a/b", Layout.flight_record("a/b", 42)) == {:ok, 42}

    for key <- [
          "gliders/a/b/_flights/0000000042",
          "gliders/a/b/_flights/0000000042/",
          "gliders/a/b/_flights/42.json",
          "gliders/a/b/_flights/0000000000.json",
          "gliders/a/b/_flights/000000004x.json",
          "gliders/a/b/_flights/0000000042.json.tmp",
          "gliders/a/b/c/_flights/0000000042.json",
          "gliders/a/_flights/0000000042.json"
        ] do
      assert Layout.flight_of_record("a/b", key) == :error, key
    end
  end

  test "a flight number out of range is refused, not wrapped" do
    assert_raise FunctionClauseError, fn -> Layout.flight_record("a", 0) end
    assert_raise FunctionClauseError, fn -> Layout.flight_record("a", 10_000_000_000) end
  end
end
