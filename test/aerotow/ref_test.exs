defmodule Aerotow.RefTest do
  use ExUnit.Case, async: true

  alias Aerotow.Ref

  doctest Aerotow.Ref

  describe "parse/1" do
    test "accepts one to eight lower-case segments" do
      for ref <-
            ~w(a code engineering/code public/site acme/eng/v1.2/code a/b/c/d/e/f/g/h x_y 0day) do
        assert Ref.parse(ref) == {:ok, ref}
      end
    end

    test "refuses anything that could leave its directory or name aerotow's own files" do
      for bad <- [
            "",
            "/",
            "/a",
            "a/",
            "a//b",
            ".",
            "..",
            "../a",
            "a/../b",
            "a/./b",
            "_flights",
            "a/_flights",
            ".hidden",
            "a/.b",
            "a.gldb",
            "a.gldb-wal/x",
            "x/y.gldb.lock",
            "A",
            "a/B",
            "a b",
            "a\\b",
            "a\nb",
            "a\0b",
            "é",
            "a-",
            "a.",
            "-a",
            "a/b/c/d/e/f/g/h/i",
            String.duplicate("a", 64),
            String.duplicate("a/", 127) <> "a"
          ] do
        assert {:error, reason} = Ref.parse(bad), "#{inspect(bad)} was accepted"
        assert reason =~ "not a ref"
      end
    end

    test "refuses what is not a string" do
      for bad <- [nil, :a, 1, ["a"], %{}, {"a"}] do
        assert {:error, _} = Ref.parse(bad)
      end
    end

    test "a segment may be 63 bytes and a ref 255" do
      assert {:ok, _} = Ref.parse(String.duplicate("a", 63))
      long = Enum.map_join(1..4, "/", fn _ -> String.duplicate("a", 63) end)
      assert byte_size(long) == 255
      assert {:ok, ^long} = Ref.parse(long)
    end
  end

  test "parse!/1 raises with the reason" do
    assert Ref.parse!("a/b") == "a/b"
    assert_raise ArgumentError, ~r/not a ref/, fn -> Ref.parse!("A") end
  end

  test "valid?/1" do
    assert Ref.valid?("a/b")
    refute Ref.valid?("a/..")
    refute Ref.valid?(nil)
  end

  test "name/1, namespace/1 and segments/1" do
    assert Ref.name("code") == "code"
    assert Ref.namespace("code") == ""
    assert Ref.name("acme/engineering/code") == "code"
    assert Ref.namespace("acme/engineering/code") == "acme/engineering"
    assert Ref.segments("acme/engineering/code") == ["acme", "engineering", "code"]
  end

  test "under?/2 matches on segment boundaries" do
    assert Ref.under?("a/b", "")
    assert Ref.under?("a/b", "a")
    assert Ref.under?("a/b", "a/")
    assert Ref.under?("a/b", "a/b")
    refute Ref.under?("ab/c", "a")
    refute Ref.under?("a", "a/b")
  end
end
