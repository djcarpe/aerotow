defmodule Aerotow.StubPlug do
  @moduledoc """
  A server for tests that answers however the test says: a function of the
  conn, called for every request.
  """

  @behaviour Plug

  @impl true
  def init(fun) when is_function(fun, 1), do: fun

  @impl true
  def call(conn, fun), do: fun.(conn)
end
