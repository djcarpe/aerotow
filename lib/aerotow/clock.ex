defmodule Aerotow.Clock do
  @moduledoc """
  The time, in unix milliseconds.

  A flight's lease is decided on it (`expires_at`, and the margin and grace
  around it), so nothing reads the system clock directly: an instance is
  given its clock, and tests give one they control.

      clock = :system
      clock = fn -> 1_763_400_000_000 end
  """

  @type t :: :system | (-> integer())

  @doc "Now, in unix milliseconds."
  @spec now(t()) :: integer()
  def now(:system), do: System.os_time(:millisecond)
  def now(clock) when is_function(clock, 0), do: clock.()

  @doc "Now, in unix seconds: what a card's timestamps are in."
  @spec seconds(t()) :: integer()
  def seconds(clock), do: div(now(clock), 1000)
end
