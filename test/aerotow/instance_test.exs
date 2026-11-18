defmodule Aerotow.InstanceTest do
  use ExUnit.Case, async: true

  alias Aerotow.Instance

  doctest Aerotow.Instance

  test "names/1 derives every part from the instance's name" do
    names = Instance.names(Some.Tow)
    assert names.catalog == Some.Tow.Catalog
    assert names.registry == Some.Tow.Registry
    assert names.flights == Some.Tow.Flights
    assert names.tasks == Some.Tow.Tasks
    assert names.server == Some.Tow.Server
    assert names.table == Some.Tow.Table
    assert map_size(names) == 6
  end

  test "an instance is found by its name while it is put, and not after" do
    name = :"instance-test-#{System.unique_integer([:positive])}"
    assert Instance.fetch(name) == {:error, :not_running}
    assert_raise ArgumentError, ~r/no aerotow named/, fn -> Instance.fetch!(name) end

    instance = %Instance{name: name, id: String.duplicate("a", 32), dir: "/nowhere"}
    :ok = Instance.put(instance)
    assert Instance.fetch(name) == {:ok, instance}
    assert Instance.fetch!(name) == instance

    :ok = Instance.delete(name)
    assert Instance.fetch(name) == {:error, :not_running}
  end

  test "the default timing is a ttl of 30 s with 5 s either side, and it checks" do
    instance = %Instance{name: :x, id: "i", dir: "/nowhere"}
    assert instance.timing == %{ttl: 30_000, margin: 5_000, grace: 5_000}
    assert Instance.check_timing(instance.timing) == {:ok, instance.timing}
  end

  test "a margin that would lose a healthy flight is refused" do
    assert {:ok, _} = Instance.check_timing(%{ttl: 300, margin: 100, grace: 0})
    assert {:error, reason} = Instance.check_timing(%{ttl: 300, margin: 200, grace: 0})
    assert reason =~ "two thirds"
    assert {:error, _} = Instance.check_timing(%{ttl: 0, margin: 1, grace: 0})
    assert {:error, _} = Instance.check_timing(%{ttl: 30_000, margin: 0, grace: 0})
    assert {:error, _} = Instance.check_timing(%{ttl: 30_000, margin: 5_000, grace: -1})
    assert {:error, _} = Instance.check_timing(%{ttl: "30s", margin: 5_000, grace: 0})
    assert {:error, _} = Instance.check_timing(%{ttl: 30_000})
    assert {:error, _} = Instance.check_timing(nil)
  end
end
