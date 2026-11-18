defmodule Aerotow.PeerTow do
  @moduledoc """
  An aerotow in a second VM, for the tests in which a VM dies.

  The VM is an OTP `:peer`, started with `start_supervised!/2`, talking to
  the test over its standard input and output (no distribution, no epmd).
  It loads this project's code, starts `:aerotow`, and runs an instance whose
  clock the test sets (`set_clock/2`), so "after `ttl + grace`" is a step of
  a clock and not a wait. `kill/1` kills its OS process, as a crash would;
  the test's own VM is never touched.

      peer = Aerotow.PeerTow.start()
      tow = Aerotow.PeerTow.tow(peer, dir: dir, stores: [{"store", path}])
      Aerotow.PeerTow.call(peer, Aerotow, :run, [tow, "g", "CREATE (:N)"])
      Aerotow.PeerTow.kill(peer)
  """

  import ExUnit.Callbacks

  @clock {__MODULE__, :clock}

  @doc "Starts a VM with this project's code and `:aerotow` running in it."
  @spec start() :: pid()
  def start do
    peer =
      start_supervised!(
        %{
          id: make_ref(),
          start: {:peer, :start_link, [%{connection: :standard_io, wait_boot: 60_000}]},
          restart: :temporary
        },
        []
      )

    :ok = call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = call(peer, :application, :ensure_all_started, [:aerotow])
    :ok = call(peer, Logger, :configure, [[level: :error]])
    peer
  end

  @doc """
  Starts an instance in the peer, with `opts` as `Aerotow.start_link/1`
  takes them and a clock that starts at `t` and moves only by
  `set_clock/2`. Answers its name.
  """
  @spec tow(pid(), keyword(), integer()) :: atom()
  def tow(peer, opts, t \\ Aerotow.FlightCase.t0()) do
    call(peer, __MODULE__, :start_here, [opts, t])
  end

  @doc false
  # Runs in the peer: the instance outlives the call that starts it.
  @spec start_here(keyword(), integer()) :: atom()
  def start_here(opts, t) do
    :persistent_term.put(@clock, t)
    name = Keyword.fetch!(opts, :name)
    {:ok, sup} = Aerotow.start_link([clock: &__MODULE__.now/0] ++ opts)
    Process.unlink(sup)
    name
  end

  @doc false
  # The peer's clock.
  @spec now() :: integer()
  def now, do: :persistent_term.get(@clock)

  @doc "Sets the peer's clock to `t`, in unix milliseconds."
  @spec set_clock(pid(), integer()) :: :ok
  def set_clock(peer, t), do: call(peer, :persistent_term, :put, [@clock, t])

  @doc "Applies `module.fun(args)` in the peer and answers what it answers."
  @spec call(pid(), module(), atom(), list()) :: term()
  def call(peer, module, fun, args), do: :peer.call(peer, module, fun, args, 120_000)

  @doc "Kills the peer's OS process, as a crash would, and waits until it is gone."
  @spec kill(pid()) :: :ok
  def kill(peer) do
    os_pid = call(peer, :os, :getpid, [])
    monitor = Process.monitor(peer)
    {_, 0} = System.cmd("kill", ["-KILL", List.to_string(os_pid)])

    receive do
      {:DOWN, ^monitor, :process, ^peer, _reason} -> :ok
    after
      30_000 -> raise "the peer VM did not go away"
    end
  end
end
