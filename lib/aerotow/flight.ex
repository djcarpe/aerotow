defmodule Aerotow.Flight do
  @moduledoc """
  A glider open on this instance: one process that holds the glider's
  lease, owns its working copy and its handle, lends the handle to callers
  for each statement, ships what is written, and lands.

  A flight is started under the instance's `DynamicSupervisor`
  (`instance.flights`), `restart: :temporary`, and registers itself in the
  instance's `Registry` (`instance.registry`) under the glider's ref, so
  there is at most one flight per ref here. `start/1` starts one and waits
  until it is up.

  ## A flight's life

  ```
                launch                         idle, evicted, or asked
    hangared ────────────▶ launching ──▶ aloft ─────────────────────▶ landing ──▶ hangared
                               │           │  ▲                          │
                               │           │  └── final ship failed ─────┘
                               ▼           ▼
                             failed       lost   (lease ran out: stop, keep the copy aside)
  ```

  The process's states have the same names: `:launching`, `:aloft`,
  `:landing`, `:lost` and `:failed` (`info/1` says which). Hangared is a
  glider with no flight process.

    * **launching** - `Aerotow.Flight.Launch` takes the flight (R9),
      restores the newest shipped state into the working copy, or makes a
      new glider and ships its first base, or carries a copy left on disk
      (R15), and opens it; the flight then records where it started. Calls
      wait until the flight is up. A launch that fails leaves nothing
      behind: no working copy, no registry entry, and the flight record it
      took landed with nothing shipped, so the next taker need not wait out
      a lease. The process is then **failed**, answers the callers that
      waited, and exits `:normal`.
    * **aloft** - statements run, each in its caller's process: the handle
      is lent with `checkout/3` and given back with `checkin/3`, or around
      a function with `run/4`. Writes make the flight dirty; a dirty flight
      ships every `sync_interval`, when `sync/2` asks, and before a write
      with `sync: :commit` is answered.
    * **landing** - on `land/2`, or when `idle` has passed with nothing
      checked out and no pin: no new checkouts (`{:error, :landing}`); the
      ones out are waited for; what is unshipped is shipped; the glider's
      counts and schema are read and its card written; the record is marked
      `landed` with what was shipped; the handle is closed and the working
      copy deleted. The process exits `:normal`. If any of that fails while
      the lease holds, the flight goes back to aloft, answering as before,
      and tries again at its next tick: nothing is deleted before it has
      shipped.
    * **lost** - the lease reached `expires_at - margin` without a renewal
      that succeeded, or a renewal found the record no longer this flight's
      (R10, R14). The flight answers `{:error, :lost}` to everything and
      ships nothing from that instant: a pass under way is abandoned. Once
      no caller holds the handle it is closed; a working copy with log that
      never shipped is moved whole to `<dir>/orphans/`, and one with
      nothing unshipped is deleted. The process exits `{:shutdown, :lost}`.

  A glider homed in a `file` store has no flight record and no shipping: it
  is opened where it lies, and glider's own lock is the guard. It is never
  lost; landing writes its card and closes it.

  ## Nobody waits on the store

  The flight process never touches the store or the handle while it is
  answering. Every renewal, record update, shipping pass and card write runs
  in a task under `instance.tasks`, and the process answers checkouts and
  `info/1` while they run. Changes to the flight's record (renewals,
  `from` and `shipped`, the landing) are made one at a time, each from the
  newest lease, so no write undoes another. A shipping pass is given
  `instance.sync_timeout`; one that takes longer is abandoned and reported
  (`[:aerotow, :sync, :exception]` with `reason: :timeout`).

  ## Time

  Every decision about the lease is made on `instance.clock`, which tests
  control. The flight looks at the clock whenever it is called and at
  every tick, once per `sync_interval` (more often when the lease's ttl is
  short): it renews every `ttl / 3`, and the moment it sees the clock at
  `expires_at - margin` it is lost, whatever a renewal stuck in the store is
  doing.

  ## Telemetry

  Spans `[:aerotow, :launch | :sync | :land, :start | :stop | :exception]`,
  with `ref`, `store`, `flight` and `mode` in their metadata; a launch's stop
  adds `from` and the measurement `bytes`; a pass's stop has the
  measurements `bytes`, `bases`, `segments` and `lag`. Events
  `[:aerotow, :lease, :renewed]`, `[:aerotow, :lease, :lost]` (with
  `reason`) and `[:aerotow, :flight, :orphaned]` (with `path`).
  """

  use GenServer, restart: :temporary

  require Logger

  alias Aerotow.{Card, Catalog, Clock, Instance, Lease, Ref, Store}
  alias Aerotow.Flight.{Copy, Launch}
  alias Aerotow.Store.Layout

  @typedoc "Why something was refused. The atoms and tagged tuples are what code branches on."
  @type reason ::
          :landing
          | :lost
          | :not_found
          | :exists
          | :no_cas
          | :timeout
          | :noproc
          | {:launch, term()}
          | {:aloft, Lease.t()}
          | String.t()
          | term()

  @typedoc "What a flight is asked to do as it starts."
  @type intent ::
          :launch
          | {:create, Card.t()}
          | {:adopt, Card.t(), Path.t()}
          | {:carry, Path.t()}

  @call_timeout 30_000

  # ------------------------------------------------------------------ starting

  @doc """
  Starts a flight. Options:

    * `:instance` - the `%Aerotow.Instance{}` it belongs to
    * `:store` - the `%Aerotow.Store{}` the glider is homed in
    * `:ref` - the glider
    * `:intent` - `:launch` (an existing glider: restore what was shipped,
      or open the file), `{:create, card}` (a new, empty glider),
      `{:adopt, card, path}` (a new glider from an existing `.gldb` file),
      or `{:carry, path}` (an existing glider, from a working copy already
      on disk, R15)
    * `:pin` - keep it aloft when it is idle (default `false`)
    * `:notify` - `{pid, tag}`: sent `{tag, :ok | {:error, reason}}` once
      the launch has succeeded or failed. `start/1` uses it

  The process registers itself and answers at once; the launch runs after.
  A ref that already has a flight here is `{:error, {:already_started,
  pid}}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, config} <- options(opts) do
      GenServer.start_link(__MODULE__, config)
    end
  end

  @doc """
  Starts a flight under `instance.flights` and waits, up to
  `instance.launch_timeout`, until it is aloft. Takes `start_link/1`'s
  options.

  Answers `{:ok, pid}`, or why it did not get up: `:not_found` (no such
  glider), `:exists` (a new glider whose ref already has a flight or a
  file), `{:aloft, lease}` (somebody else holds it), `:no_cas`,
  `{:launch, reason}` (it took a flight and could not get up; `{:launch,
  :superseded}` for a carried copy whose flight is no longer the newest,
  `{:launch, {:copy_exists, path}}` for a launch that found a working copy
  where its own would go), `:landing` (it is on its way down here: ask
  again once it has gone). A launch of a glider already aloft here answers
  that flight.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, reason()}
  def start(opts) do
    with {:ok, config} <- options(opts) do
      tag = make_ref()
      spec = {__MODULE__, Keyword.put(opts, :notify, {self(), tag})}

      case DynamicSupervisor.start_child(config.instance.flights, spec) do
        {:ok, pid} ->
          wait_launch(pid, tag, config.instance.launch_timeout)

        {:error, {:already_started, pid}} ->
          case config.intent do
            :launch ->
              with :ok <- await(pid, config.instance.launch_timeout), do: {:ok, pid}

            {:carry, _} ->
              {:error, {:already_started, pid}}

            _new ->
              {:error, :exists}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp wait_launch(pid, tag, timeout) do
    monitor = Process.monitor(pid)

    receive do
      {^tag, :ok} ->
        Process.demonitor(monitor, [:flush])
        {:ok, pid}

      {^tag, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:launch, {:exit, reason}}}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  @doc """
  Waits until a flight is aloft: `:ok`, or why it is not (`{:error,
  reason}`, as `start/1` gives it, `:landing` or `:lost`).
  """
  @spec await(pid(), timeout()) :: :ok | {:error, reason()}
  def await(pid, timeout \\ @call_timeout), do: call(pid, :await, timeout)

  defp options(opts) do
    with true <- Keyword.keyword?(opts) || {:error, "a flight's options are a keyword list"},
         {:ok, instance} <- instance(opts[:instance]),
         {:ok, store} <- store(opts[:store]),
         {:ok, ref} <- Ref.parse(opts[:ref]),
         {:ok, intent} <- intent(opts[:intent], ref),
         {:ok, pin} <- flag(Keyword.get(opts, :pin, false), "pin") do
      {:ok,
       %{
         instance: instance,
         store: store,
         ref: ref,
         intent: intent,
         pin: pin,
         notify: Keyword.get(opts, :notify)
       }}
    end
  end

  defp instance(%Instance{} = instance) do
    with {:ok, _timing} <- Instance.check_timing(instance.timing) do
      if Enum.all?([instance.registry, instance.flights, instance.tasks, instance.catalog]),
        do: {:ok, instance},
        else: {:error, "a flight's instance names its registry, flights, tasks and catalog"}
    end
  end

  defp instance(_other), do: {:error, "a flight's instance is an %Aerotow.Instance{}"}

  defp store(%Store{kind: kind} = store) when kind in [:dir, :s3, :file], do: {:ok, store}
  defp store(%Store{kind: kind}), do: {:error, "a glider in a #{kind} store does not fly here"}
  defp store(_other), do: {:error, "a flight's store is an %Aerotow.Store{}"}

  defp intent(:launch, _ref), do: {:ok, :launch}
  defp intent({:create, %Card{ref: ref}} = intent, ref), do: {:ok, intent}

  defp intent({:adopt, %Card{ref: ref}, path} = intent, ref) when is_binary(path),
    do: {:ok, intent}

  defp intent({:carry, path} = intent, _ref) when is_binary(path), do: {:ok, intent}

  defp intent(other, ref),
    do:
      {:error,
       "a flight's intent for #{ref} is :launch, {:create, card}, {:adopt, card, path} or " <>
         "{:carry, path}, with a card of #{ref}; got: #{inspect(other, limit: 5)}"}

  defp flag(flag, _name) when is_boolean(flag), do: {:ok, flag}
  defp flag(other, name), do: {:error, "#{name} is true or false, got: #{inspect(other)}"}

  # ------------------------------------------------------------------ the handle

  @doc """
  Lends the handle for one statement or one function: `{:ok, db, token}`.
  Give it back with `checkin/3`; a caller that dies has it given back for
  it. A write checkout is refused once the lease has reached its margin
  (R11): `{:error, :lost}`. While the flight is landing: `{:error,
  :landing}`. While it is launching, the call waits.
  """
  @spec checkout(pid(), :read | :write, timeout()) ::
          {:ok, Glider.db(), reference()} | {:error, reason()}
  def checkout(pid, mode, timeout \\ @call_timeout) when mode in [:read, :write] do
    token = make_ref()

    case call(pid, {:checkout, mode, token}, timeout) do
      {:error, :timeout} ->
        # It may yet be lent, after this caller stopped waiting: give it back.
        GenServer.cast(pid, {:cancel, token})
        {:error, :timeout}

      other ->
        other
    end
  end

  @doc "Gives back a checkout. `wrote?` says whether anything was written through it."
  @spec checkin(pid(), reference(), boolean()) :: :ok
  def checkin(pid, token, wrote?) when is_reference(token) and is_boolean(wrote?) do
    _ = checkin_seq(pid, token, wrote?)
    :ok
  end

  defp checkin_seq(pid, token, wrote?), do: call(pid, {:checkin, token, wrote?}, :infinity)

  @doc """
  Runs `fun.(db)` with the handle lent to the calling process, and gives it
  back after, also when `fun` raises (which is raised again) or the caller
  dies. Answers `{:ok, result}`.

  Options: `timeout:` (for the checkout, and for the ship when there is one;
  default 30 s) and `sync: :commit`, which for a write ships before
  answering, and answers `{:error, :lost}` if the lease was past its
  margin when the ship finished (R11).
  """
  @spec run(pid(), :read | :write, (Glider.db() -> result), keyword()) ::
          {:ok, result} | {:error, reason()}
        when result: term()
  def run(pid, mode, fun, opts \\ []) when mode in [:read, :write] and is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, @call_timeout)
    wrote? = mode == :write

    with {:ok, db, token} <- checkout(pid, mode, timeout) do
      result =
        try do
          fun.(db)
        catch
          kind, reason ->
            _ = checkin_seq(pid, token, wrote?)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case {checkin_seq(pid, token, wrote?), Keyword.get(opts, :sync)} do
        {{:ok, seq}, :commit} when wrote? ->
          with :ok <- call(pid, {:commit, seq}, timeout), do: {:ok, result}

        _ ->
          {:ok, result}
      end
    end
  end

  # ------------------------------------------------------------------ shipping and landing

  @doc """
  Ships now and waits for it: `{:ok, report}` with what the pass sent
  (`generation`, `position`, `bases`, `segments`, `bytes`, `lag`). A flight
  with nothing unshipped, or homed in a file store, sends nothing and says
  so.
  """
  @spec sync(pid(), timeout()) :: {:ok, map()} | {:error, reason()}
  def sync(pid, timeout \\ @call_timeout), do: call(pid, :sync, timeout)

  @doc """
  Lands the flight and waits until it has gone: what is unshipped is
  shipped, the card written, the record landed, the copy deleted. Lands a
  pinned flight too. If the last ship fails while the lease holds, the
  flight stays aloft and lands when it can; this call keeps waiting until
  `timeout`.
  """
  @spec land(pid(), timeout()) :: :ok | {:error, reason()}
  def land(pid, timeout \\ :infinity), do: call(pid, :land, timeout)

  @doc "Pins the flight (it does not land for being idle), or unpins it."
  @spec pin(pid(), boolean()) :: :ok
  def pin(pid, pinned) when is_boolean(pinned) do
    _ = call(pid, {:pin, pinned}, @call_timeout)
    :ok
  end

  @doc """
  What the flight is doing: `ref`, `store` (its name), `flight` (its
  number, `nil` in a file store), `state`, `mode`, `bytes` (of the working
  copy on disk), `dirty` (it holds writes that have not shipped),
  `checked_out` (how many checkouts are out), `pinned`, `last_used` and
  `started_at` (on the instance's clock).
  """
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info, @call_timeout)

  @doc "The glider's card, as this flight has it."
  @spec card(pid()) :: Card.t()
  def card(pid), do: GenServer.call(pid, :card, @call_timeout)

  @doc """
  Changes what somebody sets on the card (`description`, `tags`, `attrs`,
  `links`, `mode`, `hot`) and writes it to the store and the catalog. A
  field the flight owns (counts, schema, `flight`, timestamps) is refused.
  """
  @spec update_card(pid(), keyword() | map()) :: {:ok, Card.t()} | {:error, String.t() | reason()}
  def update_card(pid, changes), do: call(pid, {:update_card, changes}, @call_timeout)

  @doc """
  Reads the glider's counts and schema now, and writes the card with them
  to the store and the catalog.
  """
  @spec describe(pid()) :: {:ok, Card.t()} | {:error, reason()}
  def describe(pid) do
    case run(pid, :read, &Card.observe/1) do
      {:ok, {:ok, observation}} -> call(pid, {:observed, observation}, @call_timeout)
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  defp call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {{:shutdown, :lost}, _} -> {:error, :lost}
    :exit, {:normal, _} -> {:error, :noproc}
    :exit, {reason, _} -> {:error, {:exit, reason}}
  end

  # ------------------------------------------------------------------ the process

  @impl true
  def init(config) do
    %{instance: instance, store: store, ref: ref} = config

    case Registry.register(instance.registry, ref, store.name) do
      {:ok, _owner} ->
        now = Clock.now(instance.clock)

        state = %{
          instance: instance,
          store: store,
          ref: ref,
          intent: config.intent,
          notify: config.notify,
          objects: Store.objects?(store),
          state: :launching,
          db: nil,
          path: nil,
          lease: nil,
          from: nil,
          card: nil,
          pinned: config.pin,
          started_at: now,
          last_used: now,
          # Writes given back, and how many of them the store has. A carried
          # copy holds log that never shipped from the start.
          wseq: if(match?({:carry, _}, config.intent), do: 1, else: 0),
          shipped_seq: 0,
          shipped: nil,
          bases: 0,
          checkouts: %{},
          monitors: %{},
          deferred: [],
          launch: nil,
          launch_step: nil,
          launch_write_card: false,
          launch_waiters: [],
          launch_failure: nil,
          launch_span: nil,
          pass: nil,
          sync_waiters: [],
          commit_waiters: [],
          lane: nil,
          ops: [],
          lane_hold: false,
          card_job: nil,
          card_queue: [],
          final: nil,
          landing: nil,
          land_waiters: [],
          land_retry: false,
          land_span: nil,
          dying: %{},
          ticking: false,
          exit: nil
        }

        {:ok, state, {:continue, :launch}}

      {:error, {:already_registered, pid}} ->
        {:stop, {:already_started, pid}}
    end
  end

  @impl true
  def handle_continue(:launch, state) do
    tag = make_ref()

    ctx = %{
      instance: state.instance,
      store: state.store,
      ref: state.ref,
      intent: state.intent,
      flight: self(),
      tag: tag
    }

    span = span_start(:launch, meta(state) |> Map.put(:intent, intent_name(state.intent)))
    task = Task.Supervisor.async_nolink(state.instance.tasks, fn -> Launch.run(ctx) end)

    {:noreply,
     %{state | launch: %{ref: task.ref, pid: task.pid, tag: tag}, launch_span: span}
     |> start_ticking_if(not state.objects)}
  end

  @impl true
  def handle_call(message, from, state) do
    state
    |> dispatch(message, from)
    |> finish_call()
  end

  @impl true
  def handle_cast({:cancel, token}, state) do
    deferred =
      Enum.reject(state.deferred, fn
        {{:checkout, _mode, ^token}, _from} -> true
        _ -> false
      end)

    %{state | deferred: deferred}
    |> give_back(token, false)
    |> after_change()
    |> finish()
  end

  @impl true
  def handle_info(:tick, state) do
    state
    |> Map.put(:ticking, false)
    |> look_at_clock()
    |> tick()
    |> after_change()
    |> start_ticking_if(true)
    |> finish()
  end

  def handle_info({:taken, tag, lease}, %{launch: %{tag: tag}} = state) do
    %{state | lease: lease}
    |> start_ticking_if(true)
    |> finish()
  end

  def handle_info({:taken, _tag, _lease}, state), do: finish(state)

  def handle_info({:pass_timeout, ref}, %{pass: %{ref: ref}} = state) do
    state
    |> pass_timed_out()
    |> after_change()
    |> finish()
  end

  def handle_info({:pass_timeout, _ref}, state), do: finish(state)

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state
    |> task_done(ref, {:ok, result})
    |> after_change()
    |> finish()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.monitors, ref) ->
        token = Map.fetch!(state.monitors, ref)
        %{mode: mode} = Map.fetch!(state.checkouts, token)

        # A writer that died may have written: count it, so a copy that may
        # hold its log is never thrown away.
        state
        |> give_back(token, mode == :write)
        |> after_change()
        |> finish()

      Map.has_key?(state.dying, ref) ->
        %{state | dying: Map.delete(state.dying, ref)}
        |> after_change()
        |> finish()

      true ->
        state
        |> task_done(ref, {:crashed, reason})
        |> after_change()
        |> finish()
    end
  end

  def handle_info(_message, state), do: finish(state)

  # ------------------------------------------------------------------ calls

  defp dispatch(state, :await, from) do
    case state.state do
      :launching -> {:noreply, %{state | launch_waiters: [from | state.launch_waiters]}}
      :aloft -> {:reply, :ok, state}
      :landing -> {:reply, {:error, :landing}, state}
      :lost -> {:reply, {:error, :lost}, state}
      :failed -> {:reply, {:error, state.launch_failure}, state}
    end
  end

  defp dispatch(state, :info, _from) do
    state = state |> look_at_clock() |> idle()
    {:reply, info_of(state), state}
  end

  defp dispatch(state, :card, _from), do: {:reply, state.card, state}

  defp dispatch(state, {:pin, pinned}, _from), do: {:reply, :ok, %{state | pinned: pinned}}

  defp dispatch(%{state: :launching} = state, message, from),
    do: {:noreply, %{state | deferred: [{message, from} | state.deferred]}}

  defp dispatch(state, {:checkin, token, wrote?}, _from) do
    state = give_back(state, token, wrote?)
    {:reply, {:ok, state.wseq}, state}
  end

  defp dispatch(state, message, from) do
    state = look_at_clock(state)

    case state.state do
      :aloft -> aloft(state, message, from)
      :landing -> landing_call(state, message, from)
      :lost -> {:reply, {:error, :lost}, state}
      :failed -> {:reply, {:error, state.launch_failure}, state}
    end
  end

  defp aloft(state, {:checkout, mode, token}, {pid, _}) do
    if mode == :write and not valid?(state) do
      # R11: no write once the lease has reached its margin.
      {:reply, {:error, :lost}, go_lost(state, :deadline)}
    else
      monitor = Process.monitor(pid)
      checkout = %{pid: pid, monitor: monitor, mode: mode}

      state = %{
        state
        | checkouts: Map.put(state.checkouts, token, checkout),
          monitors: Map.put(state.monitors, monitor, token),
          last_used: now(state)
      }

      {:reply, {:ok, state.db, token}, state}
    end
  end

  defp aloft(state, {:commit, seq}, from) do
    cond do
      not state.objects ->
        {:reply, :ok, state}

      state.shipped_seq >= seq ->
        {:reply, :ok, state}

      true ->
        {:noreply, ask_pass(%{state | commit_waiters: [{from, seq} | state.commit_waiters]})}
    end
  end

  defp aloft(state, :sync, from) do
    if state.objects and dirty?(state),
      do:
        {:noreply, ask_pass(%{state | sync_waiters: [{from, state.wseq} | state.sync_waiters]})},
      else: {:reply, {:ok, nothing_shipped(state)}, state}
  end

  defp aloft(state, :land, from), do: {:noreply, begin_landing(state, from)}

  defp aloft(state, {:update_card, changes}, from) do
    case Card.change(state.card, changes) do
      {:ok, card} -> {:noreply, write_card(%{state | card: card}, from)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp aloft(state, {:observed, observation}, from) do
    card = Card.put_observation(state.card, observation, seconds(state))
    {:noreply, write_card(%{state | card: card}, from)}
  end

  defp landing_call(state, :land, from),
    do: {:noreply, %{state | land_waiters: [from | state.land_waiters]}}

  defp landing_call(state, {:commit, seq}, from) do
    if state.shipped_seq >= seq,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | commit_waiters: [{from, seq} | state.commit_waiters]}}
  end

  defp landing_call(state, :sync, from) do
    if state.objects and dirty?(state),
      do: {:noreply, %{state | sync_waiters: [{from, state.wseq} | state.sync_waiters]}},
      else: {:reply, {:ok, nothing_shipped(state)}, state}
  end

  defp landing_call(state, _message, _from), do: {:reply, {:error, :landing}, state}

  defp give_back(state, token, wrote?) do
    case Map.pop(state.checkouts, token) do
      {nil, _} ->
        state

      {%{monitor: monitor}, checkouts} ->
        Process.demonitor(monitor, [:flush])

        %{
          state
          | checkouts: checkouts,
            monitors: Map.delete(state.monitors, monitor),
            wseq: if(wrote?, do: state.wseq + 1, else: state.wseq),
            last_used: now(state)
        }
    end
  end

  defp info_of(state) do
    %{
      ref: state.ref,
      store: state.store.name,
      flight: state.lease && state.lease.n,
      state: state.state,
      mode: Copy.mode(),
      bytes: if(state.path, do: Copy.bytes(state.path), else: 0),
      dirty: dirty?(state),
      checked_out: map_size(state.checkouts),
      pinned: state.pinned,
      last_used: state.last_used,
      started_at: state.started_at
    }
  end

  defp nothing_shipped(state) do
    %{
      generation: state.shipped && state.shipped.generation,
      position: state.shipped && state.shipped.position,
      bases: 0,
      segments: 0,
      bytes: 0,
      lag: 0
    }
  end

  # ------------------------------------------------------------------ the clock

  defp now(state), do: Clock.now(state.instance.clock)
  defp seconds(state), do: Clock.seconds(state.instance.clock)

  defp valid?(%{objects: false}), do: true
  defp valid?(%{lease: nil}), do: false
  defp valid?(state), do: Lease.valid?(state.lease, now(state), state.instance.timing)

  defp dirty?(state), do: state.wseq > state.shipped_seq

  # R10: the moment the clock is at the deadline, the flight is lost.
  defp look_at_clock(%{objects: true, lease: %Lease{} = lease, state: s} = state)
       when s in [:launching, :aloft, :landing] do
    if now(state) >= Lease.deadline(lease, state.instance.timing),
      do: go_lost(state, :deadline),
      else: state
  end

  defp look_at_clock(state), do: state

  defp start_ticking_if(%{ticking: false, state: s} = state, true)
       when s in [:launching, :aloft, :landing] do
    Process.send_after(self(), :tick, tick_interval(state.instance))
    %{state | ticking: true}
  end

  defp start_ticking_if(state, _), do: state

  defp tick_interval(%Instance{sync_interval: interval, timing: %{ttl: ttl}}),
    do: max(1, min(interval, div(ttl, 10)))

  defp tick(state) do
    state
    |> renew()
    |> lane_release()
    |> ask_pass(:tick)
    |> retry_landing()
    |> idle()
  end

  defp idle(%{state: :aloft, land_waiters: [], pinned: false} = state) do
    idle = state.instance.idle

    if map_size(state.checkouts) == 0 and idle != :infinity and
         now(state) - state.last_used >= idle,
       do: begin_landing(state, nil),
       else: state
  end

  defp idle(state), do: state

  # ------------------------------------------------------------------ the record

  # Renewals, record updates and the landing are made one at a time, each
  # from the newest lease (R10).
  defp renew(%{objects: true, lease: %Lease{} = lease, lane: nil, ops: []} = state)
       when state.state in [:launching, :aloft, :landing] do
    ttl = state.instance.timing.ttl

    if now(state) >= lease.expires_at - ttl + div(ttl, 3),
      do: start_lane(state, :renew),
      else: state
  end

  defp renew(state), do: state

  defp lane_release(state), do: run_lane(%{state | lane_hold: false})

  defp enqueue(state, op), do: run_lane(%{state | ops: state.ops ++ [op]})

  defp run_lane(%{lane: nil, lane_hold: false, ops: [op | rest]} = state)
       when state.state not in [:lost, :failed] do
    start_lane(%{state | ops: rest}, op)
  end

  defp run_lane(state), do: state

  defp start_lane(state, op) do
    %{store: store, instance: instance, lease: lease} = state
    clock = instance.clock
    timing = instance.timing

    fun =
      case op do
        :renew -> fn -> Lease.renew(store, lease, clock, timing) end
        {:update, changes} -> fn -> Lease.update(store, lease, changes, clock, timing) end
        {:land, shipped} -> fn -> Lease.land(store, lease, shipped, clock, timing) end
        {:abort, from} -> fn -> Lease.land(store, %{lease | from: from}, nil, clock, timing) end
      end

    task = Task.Supervisor.async_nolink(instance.tasks, fun)
    %{state | lane: %{ref: task.ref, pid: task.pid, op: op}}
  end

  defp lane_done(state, op, result) do
    state = %{state | lane: nil}

    case {op, result} do
      {{:abort, _}, _} ->
        failed(state, state.launch_failure)

      {_, {:ok, {:ok, %Lease{} = lease}}} ->
        state = %{state | lease: lease}

        case op do
          :renew ->
            emit([:lease, :renewed], %{expires_at: lease.expires_at}, meta(state))
            state

          {:update, _} ->
            if state.state == :launching, do: launch_card(state), else: state

          {:land, _} ->
            finish_landing(state)
        end

      {_, {:ok, {:error, :lost}}} ->
        go_lost(state, :lease)

      {op, failure} ->
        reason = failure_reason(failure)

        Logger.warning(
          "aerotow: #{op_name(op)} for #{state.ref} in #{state.store.name} failed: #{text(reason)}"
        )

        case op do
          # A renewal is tried again at the next tick, until the deadline.
          :renew -> %{state | lane_hold: true}
          {:update, _} -> %{state | ops: [op | state.ops], lane_hold: true}
          {:land, _} -> back_aloft(state, reason)
        end
    end
  end

  # ------------------------------------------------------------------ launching

  defp launch_done(state, result) do
    state = %{state | launch: nil}

    case result do
      {:ok, {:ok, launched}} ->
        launched_ok(state, launched)

      {:ok, {:error, reason}} ->
        failed(state, reason)

      {:ok, {:failed, reason, from}} ->
        abort(state, reason, from)

      {:crashed, reason} ->
        # A crash after the flight was taken: what is at the working path
        # was made by this launch, except a carried copy, which stays.
        if state.lease != nil and not match?({:carry, _}, state.intent),
          do: Copy.remove(Copy.path(state.instance, state.store, state.ref))

        abort(state, {:launch, {:crashed, reason}}, nil)
    end
  end

  defp abort(%{lease: nil} = state, reason, _from), do: failed(state, reason)

  defp abort(state, reason, from) do
    run_lane(%{
      state
      | launch_failure: reason,
        launch_step: :abort,
        ops: [{:abort, from}],
        lane_hold: false
    })
  end

  defp launched_ok(state, launched) do
    state = %{
      state
      | db: launched.db,
        path: launched.path,
        card: %{launched.card | store: state.store.name},
        from: launched.from,
        shipped: launched.shipped,
        bases: (launched.shipped && launched.shipped.bases) || 0
    }

    state = if launched.dirty, do: %{state | wseq: max(state.wseq, 1)}, else: state
    state = %{state | launch_write_card: launched.write_card}

    if state.objects and launched.changes != [],
      do: enqueue(%{state | launch_step: :record}, {:update, launched.changes}),
      else: launch_card(state)
  end

  defp launch_card(state) do
    if valid?(state) do
      card = %{state.card | aloft: true}
      start_card_job(%{state | launch_step: :card, card: card}, [], state.launch_write_card)
    else
      go_lost(state, :deadline)
    end
  end

  defp aloft_now(state) do
    span_stop(
      state.launch_span,
      :launch,
      %{bytes: Copy.bytes(state.path)},
      meta(state) |> Map.put(:from, state.from)
    )

    state = %{state | state: :aloft, launch_step: nil, launch_span: nil, last_used: now(state)}
    notify(state, :ok)
    Enum.each(state.launch_waiters, &GenServer.reply(&1, :ok))
    state = %{state | launch_waiters: []}
    state = replay(state)
    state |> start_ticking_if(true) |> ask_pass(:launched)
  end

  # Calls that came while the flight was launching, in the order they came.
  defp replay(state) do
    deferred = Enum.reverse(state.deferred)

    Enum.reduce(deferred, %{state | deferred: []}, fn {message, from}, state ->
      case dispatch(state, message, from) do
        {:reply, reply, state} ->
          GenServer.reply(from, reply)
          state

        {:noreply, state} ->
          state
      end
    end)
  end

  defp failed(state, reason) do
    span_exception(state.launch_span, :launch, reason, meta(state))
    _ = Registry.unregister(state.instance.registry, state.ref)
    notify(state, {:error, reason})
    Enum.each(state.launch_waiters, &GenServer.reply(&1, {:error, reason}))
    Enum.each(state.deferred, fn {_message, from} -> GenServer.reply(from, {:error, reason}) end)

    %{
      state
      | state: :failed,
        launch_failure: reason,
        launch_waiters: [],
        deferred: [],
        launch_span: nil,
        exit: :normal
    }
  end

  defp notify(%{notify: {pid, tag}}, result), do: send(pid, {tag, result})
  defp notify(_state, _result), do: :ok

  # ------------------------------------------------------------------ shipping

  # A pass starts when the flight is dirty and somebody wants one: the tick,
  # a caller of sync/2, a write with sync: :commit, or the landing.
  defp ask_pass(state, why \\ :asked)

  defp ask_pass(%{objects: true, pass: nil, lease: %Lease{}} = state, why)
       when state.state in [:aloft, :landing] do
    wanted =
      why in [:tick, :launched, :final] or state.sync_waiters != [] or
        state.commit_waiters != []

    cond do
      not dirty?(state) or not wanted ->
        state

      # R11: no pass starts once the lease has reached its margin.
      not valid?(state) ->
        go_lost(state, :deadline)

      true ->
        start_pass(state, why == :final)
    end
  end

  defp ask_pass(state, _why), do: state

  defp start_pass(state, final?) do
    %{instance: instance, store: store, ref: ref, lease: lease, db: db, path: path} = state
    clock = instance.clock
    timing = instance.timing

    fun = fn ->
      if Lease.valid?(lease, Clock.now(clock), timing) do
        result =
          case Store.replica(store, Layout.flight_data(ref, lease.n)) do
            {url, opts} when is_binary(url) -> Copy.ship(path, db, url, opts)
            {:error, reason} -> {:error, reason}
          end

        {result, Clock.now(clock)}
      else
        {{:error, :lost}, Clock.now(clock)}
      end
    end

    span = span_start(:sync, meta(state))
    task = Task.Supervisor.async_nolink(instance.tasks, fun)
    timer = Process.send_after(self(), {:pass_timeout, task.ref}, instance.sync_timeout)

    pass = %{
      ref: task.ref,
      pid: task.pid,
      seq: state.wseq,
      final: final?,
      timer: timer,
      span: span
    }

    %{state | pass: pass}
  end

  defp pass_done(state, pass, result) do
    Process.cancel_timer(pass.timer)
    state = %{state | pass: nil}

    case result do
      {:ok, {{:ok, report}, finished_at}} ->
        if Lease.valid?(state.lease, finished_at, state.instance.timing) do
          shipped(state, pass, report)
        else
          # R11: shipped, but too late to say so.
          span_exception(pass.span, :sync, :lost, meta(state))
          go_lost(state, :deadline)
        end

      {:ok, {{:error, :lost}, _finished_at}} ->
        span_exception(pass.span, :sync, :lost, meta(state))
        go_lost(state, :deadline)

      {:ok, {{:error, reason}, _finished_at}} ->
        pass_failed(state, pass, reason)

      other ->
        pass_failed(state, pass, failure_reason(other))
    end
  end

  defp shipped(state, pass, report) do
    first_base? = state.bases == 0 and report.bases > 0
    bases = state.bases + report.bases
    shipped = %{generation: report.generation, position: report.position, bases: bases}

    span_stop(
      pass.span,
      :sync,
      Map.take(report, [:bytes, :bases, :segments, :lag]),
      meta(state) |> Map.put(:generation, report.generation)
    )

    {done, sync_waiters} = Enum.split_with(state.sync_waiters, fn {_, seq} -> seq <= pass.seq end)
    Enum.each(done, fn {from, _} -> GenServer.reply(from, {:ok, report}) end)

    {done, commit_waiters} =
      Enum.split_with(state.commit_waiters, fn {_, seq} -> seq <= pass.seq end)

    Enum.each(done, fn {from, _} -> GenServer.reply(from, :ok) end)

    state = %{
      state
      | shipped_seq: max(state.shipped_seq, pass.seq),
        shipped: shipped,
        bases: bases,
        sync_waiters: sync_waiters,
        commit_waiters: commit_waiters
    }

    # The record says shipped once there is a whole base; the landing says
    # the rest.
    state =
      if first_base? and state.state == :aloft,
        do: enqueue(state, {:update, shipped: shipped}),
        else: state

    if state.state == :landing, do: state, else: ask_pass(state)
  end

  defp pass_failed(state, pass, reason) do
    span_exception(pass.span, :sync, reason, meta(state))

    Logger.warning(
      "aerotow: shipping #{state.ref} (flight #{state.lease.n}) to #{state.store.name} " <>
        "failed: #{text(reason)}"
    )

    state = fail_waiters(state, pass.seq, {:error, reason})
    if state.state == :landing, do: back_aloft(state, reason), else: state
  end

  # A pass that has run past sync_timeout is abandoned: the flight carries
  # on, and a later pass ships what it did not.
  defp pass_timed_out(%{pass: pass} = state) do
    Process.exit(pass.pid, :kill)
    state = %{state | pass: nil, dying: Map.put(state.dying, pass.ref, :db)}
    span_exception(pass.span, :sync, :timeout, meta(state))

    Logger.warning(
      "aerotow: a pass shipping #{state.ref} to #{state.store.name} took longer than " <>
        "#{state.instance.sync_timeout} ms and was abandoned"
    )

    state = fail_waiters(state, pass.seq, {:error, :timeout})
    if state.state == :landing, do: back_aloft(state, :timeout), else: state
  end

  defp fail_waiters(state, seq, reply) do
    {done, sync_waiters} = Enum.split_with(state.sync_waiters, fn {_, s} -> s <= seq end)
    Enum.each(done, fn {from, _} -> GenServer.reply(from, reply) end)
    {done, commit_waiters} = Enum.split_with(state.commit_waiters, fn {_, s} -> s <= seq end)
    Enum.each(done, fn {from, _} -> GenServer.reply(from, reply) end)
    %{state | sync_waiters: sync_waiters, commit_waiters: commit_waiters}
  end

  # ------------------------------------------------------------------ the card

  # Card writes are made one at a time, each with the newest card.
  defp write_card(state, from) do
    cond do
      not valid?(state) ->
        GenServer.reply(from, {:error, :lost})
        go_lost(state, :deadline)

      state.card_job != nil ->
        %{state | card_queue: [from | state.card_queue]}

      true ->
        start_card_job(state, [from], true)
    end
  end

  defp start_card_job(state, waiters, write_store?) do
    %{store: store, instance: instance} = state
    card = %{state.card | store: store.name, aloft: true}

    fun = fn ->
      with :ok <- if(write_store?, do: Store.write_card(store, card), else: :ok),
           :ok <- Catalog.put_card(instance.catalog, card) do
        {:ok, card}
      end
    end

    task = Task.Supervisor.async_nolink(instance.tasks, fun)
    %{state | card_job: %{ref: task.ref, pid: task.pid, waiters: waiters}}
  end

  defp card_done(state, job, result) do
    state = %{state | card_job: nil}

    reply =
      case result do
        {:ok, {:ok, card}} -> {:ok, card}
        {:ok, {:error, reason}} -> {:error, reason}
        other -> {:error, failure_reason(other)}
      end

    Enum.each(job.waiters, &GenServer.reply(&1, reply))

    state =
      case {state.launch_step, reply} do
        {:card, {:error, reason}} ->
          Logger.warning(
            "aerotow: writing the card of #{state.ref} as it launched failed: #{text(reason)}"
          )

          aloft_now(state)

        {:card, {:ok, _card}} ->
          aloft_now(state)

        _ ->
          state
      end

    case state.card_queue do
      [] ->
        state

      waiters when state.state == :aloft ->
        start_card_job(%{state | card_queue: []}, waiters, true)

      waiters ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, state.state}))
        %{state | card_queue: []}
    end
  end

  # ------------------------------------------------------------------ landing

  defp begin_landing(state, from) do
    waiters = if from, do: [from | state.land_waiters], else: state.land_waiters

    %{
      state
      | state: :landing,
        landing: :draining,
        land_waiters: waiters,
        land_retry: false,
        land_span: span_start(:land, meta(state))
    }
    |> step_landing()
  end

  defp retry_landing(%{state: :aloft, land_retry: true} = state), do: begin_landing(state, nil)
  defp retry_landing(state), do: state

  # Each step waits for what is under way, then does the next thing.
  defp step_landing(%{state: :landing, landing: :draining} = state) do
    cond do
      map_size(state.checkouts) > 0 or state.pass != nil or state.card_job != nil ->
        state

      state.objects and dirty?(state) ->
        if valid?(state),
          do: start_pass(state, true),
          else: go_lost(state, :deadline)

      true ->
        start_final(%{state | landing: :describing})
    end
  end

  defp step_landing(state), do: state

  # The glider's counts and schema as they are now, on the card, in the
  # store. Nothing has the handle: nobody may check it out while landing.
  defp start_final(state) do
    %{store: store, instance: instance, db: db} = state
    now = seconds(state)
    card = landed_card(state)

    fun = fn ->
      with {:ok, observation} <- Card.observe(db),
           card = Card.put_observation(card, observation, now),
           :ok <- Store.write_card(store, card) do
        {:ok, card}
      end
    end

    task = Task.Supervisor.async_nolink(instance.tasks, fun)
    %{state | final: %{ref: task.ref, pid: task.pid}}
  end

  defp landed_card(%{objects: false} = state), do: %{state.card | store: state.store.name}

  defp landed_card(state) do
    {flight, generation, position} =
      case {state.shipped, state.from} do
        {%{} = shipped, _} -> {state.lease.n, shipped.generation, shipped.position}
        {nil, %{flight: flight} = from} -> {flight, from.generation, from.position}
        {nil, _} -> {state.card.flight, state.card.generation, state.card.position}
      end

    %{
      state.card
      | flight: flight,
        generation: generation,
        position: position,
        store: state.store.name
    }
  end

  defp final_done(state, result) do
    state = %{state | final: nil}

    case result do
      {:ok, {:ok, card}} ->
        state = %{state | card: card, landing: :recording}

        if state.objects,
          do: enqueue(state, {:land, record_shipped(state)}),
          else: finish_landing(state)

      {:ok, {:error, reason}} ->
        back_aloft(state, reason)

      other ->
        back_aloft(state, failure_reason(other))
    end
  end

  defp record_shipped(%{shipped: nil}), do: nil

  defp record_shipped(%{shipped: shipped}),
    do: Map.take(shipped, [:generation, :position, :bases])

  # The last ship, the card or the record could not be written, and the
  # lease holds: stay aloft, answering, and land at the next tick.
  defp back_aloft(%{state: :landing} = state, reason) do
    span_exception(state.land_span, :land, reason, meta(state))
    %{state | state: :aloft, landing: nil, land_retry: true, land_span: nil}
  end

  defp back_aloft(state, _reason), do: state

  defp finish_landing(state) do
    Glider.close(state.db)
    if state.objects, do: remove_copy(state)

    case Catalog.put_card(state.instance.catalog, %{state.card | aloft: false}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("aerotow: the catalog took no card for #{state.ref}: #{text(reason)}")
    end

    _ = Registry.unregister(state.instance.registry, state.ref)

    span_stop(
      state.land_span,
      :land,
      %{},
      meta(state) |> Map.put(:shipped, state.lease && state.lease.shipped)
    )

    Enum.each(state.land_waiters, &GenServer.reply(&1, :ok))
    %{state | db: nil, land_waiters: [], landing: nil, land_span: nil, exit: :normal}
  end

  defp remove_copy(state) do
    case Copy.remove(state.path) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("aerotow: removing the copy of #{state.ref}: #{reason}")
    end
  end

  # ------------------------------------------------------------------ lost

  # R10, R14: stop answering and ship nothing from this instant. What is
  # under way is abandoned; the handle is closed once nobody holds it.
  defp go_lost(%{state: s} = state, _why) when s in [:lost, :failed], do: state

  defp go_lost(state, why) do
    state = kill(state, :pass, true)
    state = kill(state, :final, true)
    state = kill(state, :launch, true)
    state = kill(state, :lane, false)
    state = kill(state, :card_job, false)

    emit([:lease, :lost], %{}, meta(state) |> Map.put(:reason, why))

    lost = {:error, :lost}
    if state.state == :launching, do: notify(state, lost)
    Enum.each(state.launch_waiters, &GenServer.reply(&1, lost))
    Enum.each(state.deferred, fn {_message, from} -> GenServer.reply(from, lost) end)
    Enum.each(state.land_waiters, &GenServer.reply(&1, lost))
    Enum.each(state.sync_waiters, fn {from, _} -> GenServer.reply(from, lost) end)
    Enum.each(state.commit_waiters, fn {from, _} -> GenServer.reply(from, lost) end)
    Enum.each(state.card_queue, &GenServer.reply(&1, lost))
    span_exception(state.launch_span, :launch, :lost, meta(state))
    span_exception(state.land_span, :land, :lost, meta(state))

    %{
      state
      | state: :lost,
        launch_waiters: [],
        deferred: [],
        land_waiters: [],
        sync_waiters: [],
        commit_waiters: [],
        card_queue: [],
        ops: [],
        launch_span: nil,
        land_span: nil
    }
  end

  defp kill(state, slot, uses_db?) do
    case Map.fetch!(state, slot) do
      nil ->
        state

      %{ref: ref, pid: pid} = job ->
        Process.exit(pid, :kill)
        if Map.has_key?(job, :timer), do: Process.cancel_timer(job.timer)
        if Map.has_key?(job, :span), do: span_exception(job.span, :sync, :lost, meta(state))

        if slot == :card_job,
          do: Enum.each(job.waiters, &GenServer.reply(&1, {:error, :lost}))

        dying = Map.put(state.dying, ref, if(uses_db?, do: :db, else: :other))
        Map.put(%{state | dying: dying}, slot, nil)
    end
  end

  # Once nobody holds the handle and nothing that used it is still running:
  # close it, keep the copy aside if it holds log that never shipped (R14),
  # and go.
  defp finish_lost(%{state: :lost, exit: nil} = state) do
    busy? = map_size(state.checkouts) > 0 or Enum.any?(state.dying, fn {_, use} -> use == :db end)

    if busy?, do: state, else: lost_now(state)
  end

  defp finish_lost(state), do: state

  defp lost_now(state) do
    if state.db, do: Glider.close(state.db)
    path = state.path || (state.objects && Copy.path(state.instance, state.store, state.ref))

    cond do
      not state.objects or path in [nil, false] ->
        :ok

      not Copy.exists?(path) ->
        :ok

      dirty?(state) ->
        orphan(state, path)

      true ->
        _ = Copy.remove(path)
    end

    _ = Registry.unregister(state.instance.registry, state.ref)
    _ = Catalog.set_aloft(state.instance.catalog, state.ref, false)
    %{state | db: nil, exit: {:shutdown, :lost}}
  end

  defp orphan(state, path) do
    n = state.lease.n
    to = Copy.orphan_path(state.instance, state.store, state.ref, n)

    case Copy.move(path, to) do
      :ok ->
        emit([:flight, :orphaned], %{}, meta(state) |> Map.put(:path, to))

      {:error, reason} ->
        Logger.error(
          "aerotow: flight #{n} of #{state.ref} was lost with log that never shipped, and " <>
            "its copy could not be moved aside (#{reason}); it is left at #{path}"
        )
    end
  end

  # ------------------------------------------------------------------ tasks

  defp task_done(state, ref, result) do
    cond do
      match?(%{ref: ^ref}, state.launch) -> launch_done(state, result)
      match?(%{ref: ^ref}, state.pass) -> pass_done(state, state.pass, result)
      match?(%{ref: ^ref}, state.lane) -> lane_done(state, state.lane.op, result)
      match?(%{ref: ^ref}, state.card_job) -> card_done(state, state.card_job, result)
      match?(%{ref: ^ref}, state.final) -> final_done(state, result)
      true -> %{state | dying: Map.delete(state.dying, ref)}
    end
  end

  # After anything happened: move on whatever was waiting for it.
  defp after_change(state) do
    state
    |> run_lane()
    |> step_landing()
    |> finish_lost()
  end

  defp finish_call({:reply, reply, state}) do
    state = after_change(state)

    case state.exit do
      nil -> {:reply, reply, state}
      reason -> {:stop, reason, reply, state}
    end
  end

  defp finish_call({:noreply, state}), do: state |> after_change() |> finish()

  defp finish(%{exit: nil} = state), do: {:noreply, state}
  defp finish(%{exit: reason} = state), do: {:stop, reason, state}

  # ------------------------------------------------------------------ telemetry

  defp meta(state) do
    %{
      ref: state.ref,
      store: state.store.name,
      flight: state.lease && state.lease.n,
      mode: Copy.mode()
    }
  end

  defp emit(event, measurements, metadata),
    do: :telemetry.execute([:aerotow | event], measurements, metadata)

  defp span_start(name, metadata) do
    start = System.monotonic_time()

    :telemetry.execute(
      [:aerotow, name, :start],
      %{system_time: System.system_time(), monotonic_time: start},
      metadata
    )

    start
  end

  defp span_stop(nil, _name, _measurements, _metadata), do: :ok

  defp span_stop(start, name, measurements, metadata) do
    stop = System.monotonic_time()

    :telemetry.execute(
      [:aerotow, name, :stop],
      Map.merge(measurements, %{duration: stop - start, monotonic_time: stop}),
      metadata
    )
  end

  defp span_exception(nil, _name, _reason, _metadata), do: :ok

  defp span_exception(start, name, reason, metadata) do
    stop = System.monotonic_time()

    :telemetry.execute(
      [:aerotow, name, :exception],
      %{duration: stop - start, monotonic_time: stop},
      Map.merge(metadata, %{kind: :error, reason: reason})
    )
  end

  # ------------------------------------------------------------------ helpers

  defp intent_name(:launch), do: :launch
  defp intent_name({name, _}), do: name
  defp intent_name({name, _, _}), do: name

  defp op_name(:renew), do: "renewing the lease"
  defp op_name({:update, _}), do: "updating the flight record"
  defp op_name({:land, _}), do: "landing the flight record"

  defp failure_reason({:ok, {:error, reason}}), do: reason
  defp failure_reason({:ok, other}), do: {:unexpected, other}
  defp failure_reason({:crashed, reason}), do: {:crashed, reason}
  defp failure_reason(other), do: other

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)
end
