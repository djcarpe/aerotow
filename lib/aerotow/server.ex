defmodule Aerotow.Server do
  @moduledoc """
  The process that holds an instance together: its id, its stores and their
  credentials, room for flights, and the scans.

  ## Starting

  As it starts, the server

    1. reads the instance's id from `<dir>/instance.json`, or makes one (32
       hex digits) and writes it there; an `id:` given overrides the file
       and is written;
    2. sets aside the working copies left under `<dir>/flights/`
       (`Aerotow.Copies.at_start/1`), so no launch trips over one;
    3. records in the catalog that nothing is aloft here any more;
    4. makes each store with `Aerotow.Store.new/3`, all at once, giving each
       #{div(10_000, 1000)} s; a store that cannot be made is kept as
       unavailable, with its reason, and tried again with a backoff from
       1 s doubling to 60 s;
    5. makes the instance findable (`Aerotow.Instance.put/1`).

  Then every available store is scanned, and again every `scan_interval`.

  ## The table

  The instance's ETS table, owned by this process, is read by any process
  without a call: the stores (with their credentials, inside each store's
  config), the refs being purged, and the gliders written here since their
  card was last observed. Only this process writes the stores.

  ## Room

  A launch asks for room first (`room/2`). Past `max_aloft` flights here, or
  `budget` bytes of working copies, the least recently used flight that has
  nothing checked out and is not pinned is landed, in a task, and the
  launch waits for it. A flight already on its way down is waited for. If
  no flight can land, the answer is `{:error, :too_many_aloft}`. Room given
  is held for the caller until it says `done/2` or exits, so launches at once
  never overshoot.

  ## Stopping

  The instance is made unfindable first, so no new call starts a launch.
  Then every flight here is landed, all at once, for at most
  #{div(30_000, 1000)} s. A flight that has not landed by then is stopped
  with the rest of the tree; its working copy stays on disk, and the next
  start sets it aside.
  """

  use GenServer

  require Logger

  alias Aerotow.{Catalog, Copies, Flight, Instance, Options, Scan, Store}

  @connect_timeout 10_000
  @land_bound 30_000
  @backoff_first 1_000
  @backoff_max 60_000
  @id_format 1
  @max_id_file 4_096

  @doc "How long a supervisor gives the server to stop: the landing bound, and some."
  @spec shutdown() :: pos_integer()
  def shutdown, do: @land_bound + 10_000

  @doc "Starts the server of an instance, from checked options."
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(config) do
    names = Instance.names(config.name)
    GenServer.start_link(__MODULE__, config, name: names.server)
  end

  # ------------------------------------------------------------------ reads

  @doc """
  The store `name`, as the table has it: `{:ok, store}`, or
  `{:error, {:store_unavailable, name, reason}}` for a store that cannot be
  reached now or that this instance does not have.
  """
  @spec store(Instance.t(), String.t()) ::
          {:ok, Store.t()} | {:error, {:store_unavailable, String.t(), String.t()}}
  def store(%Instance{table: table}, name) when is_binary(name) do
    case lookup(table, {:store, name}) do
      [{_, _index, %Store{} = store, nil, _shown}] -> {:ok, store}
      [{_, _index, nil, reason, _shown}] -> {:error, {:store_unavailable, name, reason}}
      [] -> {:error, {:store_unavailable, name, "this aerotow has no store of that name"}}
    end
  end

  def store(_instance, name),
    do: {:error, {:store_unavailable, inspect(name), "not a store's name"}}

  @doc "The stores that can be reached now, in the order they were given."
  @spec available_stores(Instance.t()) :: [Store.t()]
  def available_stores(%Instance{table: table}) do
    for {_, _index, %Store{} = store, nil, _} <- rows(table), do: store
  end

  @doc """
  Every store, in the order given, without credentials: name, kind, url,
  cas, `available`, and `reason` when it is not.
  """
  @spec stores(Instance.t()) :: [map()]
  def stores(%Instance{table: table}) do
    for {_, _index, store, reason, shown} <- rows(table) do
      case store do
        %Store{} -> store |> Store.public() |> Map.merge(%{available: true, reason: nil})
        nil -> Map.merge(shown, %{cas: nil, available: false, reason: reason})
      end
    end
  end

  defp rows(table) do
    table
    |> match({{:store, :_}, :_, :_, :_, :_})
    |> Enum.sort_by(&elem(&1, 1))
  end

  @doc "Whether this instance is purging `ref` now."
  @spec purging?(Instance.t(), String.t()) :: boolean()
  def purging?(%Instance{table: table}, ref), do: lookup(table, {:purging, ref}) != []

  @doc "Marks `ref` as written since its card was last observed."
  @spec written(Instance.t(), String.t()) :: :ok
  def written(%Instance{table: table}, ref) do
    _ = safely(fn -> :ets.insert(table, {{:stale, ref}, true}) end, false)
    :ok
  end

  @doc "Takes the refs written since their card was last observed, and forgets them."
  @spec take_written(Instance.t()) :: [String.t()]
  def take_written(%Instance{table: table}) do
    table
    |> match({{:stale, :_}, :_})
    |> Enum.flat_map(fn {{:stale, ref} = key, _} ->
      case safely(fn -> :ets.take(table, key) end, []) do
        [_] -> [ref]
        [] -> []
      end
    end)
  end

  defp lookup(table, key), do: safely(fn -> :ets.lookup(table, key) end, [])
  defp match(table, pattern), do: safely(fn -> :ets.match_object(table, pattern) end, [])

  # The table goes with a server that stops; a reader then finds nothing.
  defp safely(fun, default) do
    fun.()
  rescue
    ArgumentError -> default
  end

  # ------------------------------------------------------------------ calls

  @doc """
  Room for one more flight, for a launch of `ref`. `{:ok, token}`: the
  room is held until `done/2` with the token, or until the caller exits.
  `{:ok, nil}` when `ref` already has a flight here and needs no room.
  """
  @spec room(Instance.t(), String.t()) :: {:ok, reference() | nil} | {:error, :too_many_aloft}
  def room(%Instance{} = instance, ref),
    do: call(instance, {:room, ref}, instance.launch_timeout)

  @doc "Gives back room `room/2` held."
  @spec done(Instance.t(), reference() | nil) :: :ok
  def done(_instance, nil), do: :ok
  def done(%Instance{server: server}, token), do: GenServer.cast(server, {:done, token})

  @doc """
  Scans stores now and waits for it: `:all`, or one store's name. A scan
  under way when this is asked is followed by another, so what was in the
  store when this was asked is seen.
  """
  @spec scan(Instance.t(), :all | String.t()) ::
          {:ok, %{String.t() => {:ok, Scan.summary()} | {:error, term()}}}
  def scan(%Instance{} = instance, which), do: call(instance, {:scan, which}, :infinity)

  @doc "Adds a store that `Aerotow.Store.new/3` has made, records it in the catalog."
  @spec attach_store(Instance.t(), Store.t(), Options.store_spec()) :: :ok | {:error, term()}
  def attach_store(%Instance{} = instance, %Store{} = store, spec),
    do: call(instance, {:attach, store, spec}, :infinity)

  @doc "Whether a store of that name is there, available or not."
  @spec store?(Instance.t(), String.t()) :: boolean()
  def store?(%Instance{table: table}, name), do: lookup(table, {:store, name}) != []

  @doc "Takes a store out of the table, so nothing is routed to it any more."
  @spec detach_store(Instance.t(), String.t()) :: :ok | {:error, :not_found}
  def detach_store(%Instance{} = instance, name), do: call(instance, {:detach, name}, :infinity)

  @doc """
  Marks `ref` as being purged by the calling process, until `unpurge/2` or
  the caller exits: `{:error, :purging}` if another process is purging it.
  """
  @spec purge(Instance.t(), String.t()) :: :ok | {:error, :purging}
  def purge(%Instance{} = instance, ref), do: call(instance, {:purge, ref}, :infinity)

  @doc "Ends a purge."
  @spec unpurge(Instance.t(), String.t()) :: :ok
  def unpurge(%Instance{} = instance, ref), do: call(instance, {:unpurge, ref}, :infinity)

  defp call(%Instance{server: server}, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :not_running}
  end

  # ------------------------------------------------------------------ starting

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    names = Instance.names(config.name)

    with :ok <- make_dir(config.dir),
         {:ok, id} <- instance_id(config.dir, config.id) do
      instance =
        struct!(
          Instance,
          [
            name: config.name,
            id: id,
            dir: config.dir,
            node: Options.node_name(),
            catalog: names.catalog,
            registry: names.registry,
            flights: names.flights,
            tasks: names.tasks,
            server: names.server,
            table: names.table
          ] ++ config.fields
        )

      table = :ets.new(names.table, [:set, :public, :named_table, read_concurrency: true])
      Copies.at_start(instance)
      grounded(instance)

      state = %{
        instance: instance,
        table: table,
        specs: Map.new(config.stores, &{&1.name, &1}),
        next_index: length(config.stores),
        retries: %{},
        connecting: %{},
        scans: %{},
        jobs: %{},
        reservations: %{},
        pending: :queue.new(),
        evicting: nil,
        purges: %{}
      }

      state =
        config.stores
        |> Enum.with_index()
        |> connect_all(state)

      :ok = Instance.put(instance)
      {:ok, state, {:continue, :started}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:started, state) do
    state = start_scans(state, available_names(state), nil)
    schedule_scan(state.instance)
    {:noreply, state}
  end

  defp make_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot make #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # The id in <dir>/instance.json, or a new one written there. One given
  # overrides the file.
  defp instance_id(dir, given) do
    path = Path.join(dir, "instance.json")

    case {given, read_id(path)} do
      {nil, {:ok, id}} -> {:ok, id}
      {nil, :missing} -> write_id(path, random_id())
      {nil, {:error, reason}} -> {:error, reason}
      {id, {:ok, id}} -> {:ok, id}
      {id, _} -> write_id(path, id)
    end
  end

  defp read_id(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_id_file ->
        with {:ok, body} <- File.read(path),
             {:ok, %{"format" => @id_format, "id" => id}} when is_binary(id) <- JSON.decode(body),
             true <- Regex.match?(~r/\A[0-9a-f]{32}\z/, id) do
          {:ok, id}
        else
          _ -> {:error, "#{path} is not an instance's id file; move it away or give id:"}
        end

      {:error, :enoent} ->
        :missing

      _ ->
        {:error, "#{path} is not an instance's id file; move it away or give id:"}
    end
  end

  defp write_id(path, id) do
    body = "{\n  \"format\": #{@id_format},\n  \"id\": #{JSON.encode!(id)}\n}\n"
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      {:ok, id}
    else
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Nothing is aloft here as the instance starts, except flights that kept
  # flying while the server was started again.
  defp grounded(instance) do
    case Catalog.find(instance.catalog, "MATCH (g:Glider {aloft: true}) RETURN g.ref") do
      {:ok, %{rows: rows}} ->
        for [ref] <- rows, Registry.lookup(instance.registry, ref) == [] do
          _ = Catalog.set_aloft(instance.catalog, ref, false)
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  # ------------------------------------------------------------------ stores

  defp connect_all(indexed, state) do
    clock = state.instance.clock

    results =
      indexed
      |> Task.async_stream(fn {spec, _index} -> connect(spec, clock) end,
        timeout: @connect_timeout,
        on_timeout: :kill_task,
        max_concurrency: max(length(indexed), 1),
        ordered: true
      )
      |> Enum.zip(indexed)

    Enum.reduce(results, state, fn {result, {spec, index}}, state ->
      result =
        case result do
          {:ok, result} -> result
          {:exit, :timeout} -> {:error, "it did not answer within #{@connect_timeout} ms"}
          {:exit, reason} -> {:error, "making it crashed: #{inspect(reason)}"}
        end

      connected(state, spec, index, result)
    end)
  end

  defp connect(spec, clock) do
    opts = Keyword.put_new(spec.opts.(), :clock, clock)
    Store.new(spec.name, spec.url, opts)
  end

  defp connected(state, spec, index, {:ok, store}) do
    case Catalog.put_store(state.instance.catalog, Store.public(store)) do
      :ok ->
        put_row(state, spec, index, store, nil)
        %{state | retries: Map.delete(state.retries, spec.name)}

      {:error, reason} ->
        unavailable(state, spec, index, "the catalog did not take it: #{reason}")
    end
  end

  defp connected(state, spec, index, {:error, reason}),
    do: unavailable(state, spec, index, text(reason))

  defp unavailable(state, spec, index, reason) do
    Logger.warning("aerotow: store #{inspect(spec.name)} is unavailable: #{reason}")
    put_row(state, spec, index, nil, reason)

    backoff =
      state.retries
      |> Map.get(spec.name, div(@backoff_first, 2))
      |> Kernel.*(2)
      |> min(@backoff_max)

    Process.send_after(self(), {:retry, spec.name}, backoff)
    %{state | retries: Map.put(state.retries, spec.name, backoff)}
  end

  defp put_row(state, spec, index, store, reason) do
    shown = %{name: spec.name, kind: nil, url: strip_userinfo(spec.url)}
    true = :ets.insert(state.table, {{:store, spec.name}, index, store, reason, shown})
  end

  defp strip_userinfo(url) do
    case URI.parse(url) do
      %URI{userinfo: info} = uri when is_binary(info) -> URI.to_string(%{uri | userinfo: nil})
      _ -> url
    end
  end

  defp available_names(state) do
    for {_, _, %Store{name: name}, nil, _} <- rows(state.table), do: name
  end

  # ------------------------------------------------------------------ handle_call

  @impl true
  def handle_call({:room, ref}, from, state) do
    {:noreply, %{state | pending: :queue.in({from, ref}, state.pending)} |> make_room()}
  end

  def handle_call({:scan, which}, from, state) do
    names =
      case which do
        :all -> Enum.map(rows(state.table), fn {{:store, name}, _, _, _, _} -> name end)
        name -> [name]
      end

    {:noreply, start_job(state, names, from)}
  end

  def handle_call({:attach, store, spec}, _from, state) do
    cond do
      Map.has_key?(state.specs, store.name) or lookup(state.table, {:store, store.name}) != [] ->
        {:reply, {:error, :exists}, state}

      true ->
        case Catalog.put_store(state.instance.catalog, Store.public(store)) do
          :ok ->
            put_row(state, spec, state.next_index, store, nil)

            {:reply, :ok,
             %{
               state
               | specs: Map.put(state.specs, store.name, spec),
                 next_index: state.next_index + 1
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:detach, name}, _from, state) do
    if lookup(state.table, {:store, name}) == [] do
      {:reply, {:error, :not_found}, state}
    else
      :ets.delete(state.table, {:store, name})

      {:reply, :ok,
       %{
         state
         | specs: Map.delete(state.specs, name),
           retries: Map.delete(state.retries, name)
       }}
    end
  end

  def handle_call({:purge, ref}, {pid, _}, state) do
    if :ets.insert_new(state.table, {{:purging, ref}, pid}) do
      monitor = Process.monitor(pid)
      {:reply, :ok, %{state | purges: Map.put(state.purges, monitor, ref)}}
    else
      {:reply, {:error, :purging}, state}
    end
  end

  def handle_call({:unpurge, ref}, _from, state) do
    :ets.delete(state.table, {:purging, ref})

    purges =
      case Enum.find(state.purges, fn {_monitor, r} -> r == ref end) do
        {monitor, _} ->
          Process.demonitor(monitor, [:flush])
          Map.delete(state.purges, monitor)

        nil ->
          state.purges
      end

    {:reply, :ok, %{state | purges: purges}}
  end

  @impl true
  def handle_cast({:done, token}, state), do: {:noreply, release(state, token) |> make_room()}

  # ------------------------------------------------------------------ handle_info

  @impl true
  def handle_info({:retry, name}, state) do
    case Map.fetch(state.specs, name) do
      {:ok, spec} ->
        connecting? = name in Map.values(state.connecting)

        if connecting? or available_row?(lookup(state.table, {:store, name})) do
          {:noreply, state}
        else
          clock = state.instance.clock

          task =
            Task.Supervisor.async_nolink(state.instance.tasks, fn -> connect(spec, clock) end)

          {:noreply, %{state | connecting: Map.put(state.connecting, task.ref, name)}}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:scan_timer, state) do
    schedule_scan(state.instance)
    {:noreply, start_scans(state, available_names(state), nil)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, task_done(state, ref, {:ok, result})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.purges, ref) ->
        :ets.delete(state.table, {:purging, Map.fetch!(state.purges, ref)})
        {:noreply, %{state | purges: Map.delete(state.purges, ref)}}

      match?({:waiting, ^ref}, state.evicting) ->
        {:noreply, %{state | evicting: nil} |> make_room()}

      Enum.any?(state.reservations, fn {_token, {monitor, _}} -> monitor == ref end) ->
        {token, _} =
          Enum.find(state.reservations, fn {_token, {monitor, _}} -> monitor == ref end)

        {:noreply, release(state, token) |> make_room()}

      true ->
        {:noreply, task_done(state, ref, {:crashed, reason})}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp available_row?([{_, _, %Store{}, nil, _}]), do: true
  defp available_row?(_), do: false

  defp task_done(state, ref, result) do
    cond do
      Map.has_key?(state.connecting, ref) ->
        name = Map.fetch!(state.connecting, ref)
        state = %{state | connecting: Map.delete(state.connecting, ref)}
        reconnected(state, name, result)

      match?({:landing, ^ref}, state.evicting) ->
        %{state | evicting: nil} |> make_room()

      store = Enum.find_value(state.scans, fn {name, s} -> if s.task == ref, do: name end) ->
        scan_done(state, store, result)

      true ->
        state
    end
  end

  defp reconnected(state, name, result) do
    with {:ok, spec} <- Map.fetch(state.specs, name),
         [{_, index, _, _, _}] <- lookup(state.table, {:store, name}) do
      result =
        case result do
          {:ok, result} -> result
          {:crashed, reason} -> {:error, "making it crashed: #{inspect(reason)}"}
        end

      state = connected(state, spec, index, result)

      if match?({:ok, _}, result) do
        Logger.info("aerotow: store #{inspect(name)} is available")
        start_scans(state, [name], nil)
      else
        state
      end
    else
      _ -> state
    end
  end

  # ------------------------------------------------------------------ scans

  defp schedule_scan(%Instance{scan_interval: nil}), do: :ok

  defp schedule_scan(%Instance{scan_interval: interval}),
    do: Process.send_after(self(), :scan_timer, interval)

  # A job is one caller waiting for scans of some stores (or a timer's,
  # with no caller). Each store runs one scan at a time; a job that comes
  # while one runs waits for the next.
  defp start_job(state, [], from) do
    if from, do: GenServer.reply(from, {:ok, %{}})
    state
  end

  defp start_job(state, names, from) do
    job = make_ref()

    state = %{
      state
      | jobs: Map.put(state.jobs, job, %{from: from, left: MapSet.new(names), results: %{}})
    }

    Enum.reduce(names, state, fn name, state ->
      case store(state.instance, name) do
        {:ok, store} -> attach_scan(state, store, job)
        {:error, reason} -> job_result(state, job, name, {:error, reason})
      end
    end)
  end

  defp start_scans(state, names, from), do: start_job(state, names, from)

  defp attach_scan(state, store, job) do
    case Map.get(state.scans, store.name) do
      nil ->
        run_scan(state, store, [job])

      %{task: nil} ->
        run_scan(state, store, [job])

      running ->
        put_in(state.scans[store.name], %{running | again: [job | running.again]})
    end
  end

  defp run_scan(state, store, jobs) do
    instance = state.instance
    task = Task.Supervisor.async_nolink(instance.tasks, fn -> Scan.run(instance, store) end)
    put_in(state.scans[store.name], %{task: task.ref, jobs: jobs, again: []})
  end

  defp scan_done(state, name, result) do
    %{jobs: jobs, again: again} = Map.fetch!(state.scans, name)

    result =
      case result do
        {:ok, {:ok, summary}} -> {:ok, summary}
        {:ok, {:error, reason}} -> {:error, reason}
        {:crashed, reason} -> {:error, "the scan crashed: #{inspect(reason)}"}
      end

    case result do
      {:error, reason} ->
        Logger.warning("aerotow: scanning #{inspect(name)} failed: #{text(reason)}")

      _ ->
        :ok
    end

    state = put_in(state.scans[name], %{task: nil, jobs: [], again: []})
    state = Enum.reduce(jobs, state, &job_result(&2, &1, name, result))

    case {again, store(state.instance, name)} do
      {[], _} ->
        state

      {again, {:ok, store}} ->
        run_scan(state, store, again)

      {again, {:error, reason}} ->
        Enum.reduce(again, state, &job_result(&2, &1, name, {:error, reason}))
    end
  end

  defp job_result(state, job, name, result) do
    case Map.fetch(state.jobs, job) do
      {:ok, %{left: left, results: results} = j} ->
        j = %{j | left: MapSet.delete(left, name), results: Map.put(results, name, result)}

        if MapSet.size(j.left) == 0 do
          if j.from, do: GenServer.reply(j.from, {:ok, j.results})
          %{state | jobs: Map.delete(state.jobs, job)}
        else
          %{state | jobs: Map.put(state.jobs, job, j)}
        end

      :error ->
        state
    end
  end

  # ------------------------------------------------------------------ room

  defp release(state, token) do
    case Map.pop(state.reservations, token) do
      {nil, _} ->
        state

      {{monitor, _ref}, reservations} ->
        Process.demonitor(monitor, [:flush])
        %{state | reservations: reservations}
    end
  end

  # Answers the callers waiting for room, in order, while nothing is being
  # landed to make it.
  defp make_room(%{evicting: nil} = state) do
    case :queue.out(state.pending) do
      {:empty, _} ->
        state

      {{:value, {from, ref} = head}, rest} ->
        case decide(state, ref) do
          :here ->
            GenServer.reply(from, {:ok, nil})
            make_room(%{state | pending: rest})

          :room ->
            {pid, _} = from
            token = make_ref()
            monitor = Process.monitor(pid)
            GenServer.reply(from, {:ok, token})

            make_room(%{
              state
              | pending: rest,
                reservations: Map.put(state.reservations, token, {monitor, ref})
            })

          {:evict, victim, why} ->
            evict(%{state | pending: :queue.in_r(head, rest)}, victim, why)

          {:wait, pid} ->
            %{
              state
              | pending: :queue.in_r(head, rest),
                evicting: {:waiting, Process.monitor(pid)}
            }

          :full ->
            GenServer.reply(from, {:error, :too_many_aloft})
            make_room(%{state | pending: rest})
        end
    end
  end

  defp make_room(state), do: state

  defp decide(state, ref) do
    instance = state.instance

    if Registry.lookup(instance.registry, ref) != [] do
      :here
    else
      flights = flights(instance)

      # Room held for a launch whose flight has registered is counted once,
      # as the flight.
      held =
        Enum.count(state.reservations, fn {_token, {_monitor, held}} ->
          Registry.lookup(instance.registry, held) == []
        end)

      count = length(flights) + held
      bytes = flights |> Enum.map(& &1.bytes) |> Enum.sum()

      why =
        cond do
          count >= instance.max_aloft -> :max_aloft
          instance.budget != nil and bytes >= instance.budget -> :budget
          true -> nil
        end

      cond do
        why == nil ->
          :room

        victim = lru(flights) ->
          {:evict, victim, why}

        landing = Enum.find(flights, &(&1.state == :landing)) ->
          {:wait, landing.pid}

        true ->
          :full
      end
    end
  end

  defp flights(instance) do
    instance.registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {_ref, pid} ->
      try do
        [Map.put(Flight.info(pid), :pid, pid)]
      catch
        :exit, _ -> []
      end
    end)
  end

  # The least recently used flight that can land for room: aloft, nothing
  # checked out, not pinned.
  defp lru(flights) do
    flights
    |> Enum.filter(&(&1.state == :aloft and &1.checked_out == 0 and not &1.pinned))
    |> Enum.min_by(& &1.last_used, fn -> nil end)
  end

  defp evict(state, victim, why) do
    :telemetry.execute([:aerotow, :evict], %{bytes: victim.bytes}, %{
      ref: victim.ref,
      store: victim.store,
      flight: victim.flight,
      why: why
    })

    timeout = state.instance.sync_timeout
    pid = victim.pid
    task = Task.Supervisor.async_nolink(state.instance.tasks, fn -> Flight.land(pid, timeout) end)
    %{state | evicting: {:landing, task.ref}}
  end

  # ------------------------------------------------------------------ stopping

  @impl true
  def terminate(_reason, state) do
    instance = state.instance
    :ok = Instance.delete(instance.name)

    instance.registry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Task.async_stream(&Flight.land(&1, @land_bound),
      timeout: @land_bound,
      on_timeout: :kill_task,
      max_concurrency: 64,
      ordered: false
    )
    |> Stream.run()

    :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def format_status(status) do
    # The stores' options are behind functions and their configs are not
    # shown by inspect; the specs are left out all the same.
    Map.update(status, :state, nil, fn
      %{} = state -> Map.drop(state, [:specs])
      other -> other
    end)
  end

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)
end
