defmodule Aerotow.ClockTest do
  use ExUnit.Case, async: true

  alias Aerotow.Clock

  test "the system clock is unix milliseconds" do
    now = Clock.now(:system)
    assert_in_delta now, System.os_time(:millisecond), 5_000

    assert Clock.seconds(:system) == div(now, 1000) or
             Clock.seconds(:system) == div(now, 1000) + 1
  end

  test "a clock that is given is the one that is read" do
    clock = fn -> 1_763_400_000_123 end
    assert Clock.now(clock) == 1_763_400_000_123
    assert Clock.seconds(clock) == 1_763_400_000
  end
end
