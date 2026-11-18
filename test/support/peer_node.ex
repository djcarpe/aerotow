defmodule Aerotow.PeerNode do
  @moduledoc """
  What a test runs on a second node, started with OTP's `:peer`: an
  aerotow started there and left running after the call that started it.
  """

  @doc "Starts the applications aerotow needs, and an instance with `opts`, not linked to the caller."
  @spec start_instance(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_instance(opts) do
    {:ok, _} = Application.ensure_all_started(:aerotow)

    case Aerotow.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      error ->
        error
    end
  end
end
