defmodule Aerotow.Flight.Launch do
  @moduledoc """
  Getting a glider up: the part of a flight's launch that reads and writes
  the store and the disk, run in a task so that the flight itself keeps
  answering (and, once it has a lease, renewing it) while a large glider is
  restored.

  `run/1` takes the flight (R7, R9), tells the flight its lease the moment
  it has one (`{:taken, tag, lease}`, sent to `ctx.flight`), and then makes
  the working copy, in memory or on disk as `Aerotow.Flight.Copy.decide/4`
  says from the card:

    * `:launch` - restores the newest state an earlier flight shipped
      (R12, R13) and opens it. A glider that `"auto"` put in memory and
      that does not fit there is restored to disk instead; one that is
      `"memory"` by name fails, with glider's reason
    * `{:create, card}` - an empty database, and its first base shipped
    * `{:adopt, card, path}` - a copy of an existing database file, and its
      first base shipped. It flies from disk, being a file
    * `{:carry, path}` - a working copy already on disk, whose flight is
      still the newest in the store (R15), moved into place and opened
      (from disk); or the replica a lost memory flight left in `orphans/`,
      restored into memory or to disk as the card says, and then removed

  After it has sent the lease it writes nothing more to the flight's
  record: every later change to the record is the flight's, made one at a
  time, so that a renewal and an update never overwrite each other.

  It answers one of:

    * `{:ok, launched}` - the glider is open: the handle, where it is, its
      card, where it started (`from`), what it shipped, the changes the
      flight is to record, and whether the copy holds log that has not
      shipped
    * `{:error, reason}` - it never took a flight, and nothing was written
    * `{:failed, reason, from}` - it took a flight and could not get up.
      What it made on disk is gone (a carried copy is put back where it
      was), and the flight is to land its record with `from` and nothing
      shipped
  """

  alias Aerotow.{Card, Clock, Instance, Lease, Store}
  alias Aerotow.Flight.Copy
  alias Aerotow.Store.Layout

  @typedoc "What a launch needs: the flight it is for, and what to do."
  @type ctx :: %{
          instance: Instance.t(),
          store: Store.t(),
          ref: Aerotow.Ref.t(),
          intent: term(),
          flight: pid(),
          tag: reference()
        }

  @typedoc """
  A glider that got up: its handle, where its working copy is (`nil` in
  memory), its card, the mode it flies in (`Aerotow.Flight.Copy.decide/4`),
  what it measured as it got up, …
  """
  @type launched :: %{
          db: Glider.db(),
          path: Path.t() | nil,
          card: Card.t(),
          mode: Copy.mode(),
          measured: Copy.measured() | nil,
          from: Lease.from() | nil,
          shipped: Lease.shipped() | nil,
          changes: keyword(),
          dirty: boolean(),
          write_card: boolean()
        }

  @doc "Launches, as the moduledoc says. Run in a task; never raises for what it is given."
  @spec run(ctx()) :: {:ok, launched()} | {:error, term()} | {:failed, term(), Lease.from() | nil}
  def run(%{store: store} = ctx) do
    if Store.objects?(store), do: objects(ctx), else: file(ctx)
  end

  @doc """
  Whether the replica at `url` holds a whole base: the `whole_base?` that
  `Aerotow.Lease.source/4` and `Aerotow.Lease.retire/5` take.
  """
  @spec whole_base?(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def whole_base?(url, opts) do
    with {:ok, gens} <- Glider.Replication.generations(url, opts), do: {:ok, gens != []}
  end

  # ------------------------------------------------------------------ object stores

  defp objects(%{intent: :launch} = ctx) do
    path = working(ctx)

    with :ok <- no_copy(path),
         {:ok, lease} <- take(ctx, takeover_own: true) do
      taken(ctx, lease)
      restore(ctx, lease, path)
    end
  end

  defp objects(%{intent: {:create, card}} = ctx), do: new(ctx, card, nil)
  defp objects(%{intent: {:adopt, card, from}} = ctx), do: new(ctx, card, from)
  defp objects(%{intent: {:carry, path}} = ctx), do: carry(ctx, path)

  # The card in the store says where the pages live (Copy.decide/4); then
  # the newest shipped state is brought up there.
  defp restore(ctx, lease, path) do
    with {:ok, source} <- source(ctx, lease),
         from = %{flight: source, generation: nil, position: nil},
         {:ok, card} <- stored_card(ctx, from),
         {:ok, url, opts} <- source_replica(ctx, source, from),
         mode = Copy.decide(ctx.instance, ctx.store, card),
         {:ok, up} <- bring_up(ctx, mode, card, url, opts, path, lease.n, from) do
      from = %{from | generation: up.generation, position: up.position}

      {:ok,
       launched(up, card,
         from: from,
         shipped: nil,
         changes: [from: from],
         dirty: false,
         write_card: false
       )}
    end
  end

  # R12: the newest earlier flight with a whole base, found by looking.
  defp source(ctx, lease) do
    case Lease.source(ctx.store, ctx.ref, lease.n, &whole_base?/2) do
      {:ok, %{flight: n}} ->
        {:ok, n}

      {:ok, nil} ->
        {:failed, {:launch, "no earlier flight of #{ctx.ref} shipped a whole base"}, nil}

      {:error, reason} ->
        {:failed, launch_reason(reason), nil}
    end
  end

  defp source_replica(ctx, source, from) do
    case replica(ctx, source) do
      {:ok, url, opts} -> {:ok, url, opts}
      {:error, reason} -> {:failed, {:launch, "restoring flight #{source}: #{reason}"}, from}
    end
  end

  defp stored_card(ctx, from) do
    case Store.read_card(ctx.store, ctx.ref) do
      {:ok, card} -> {:ok, card}
      {:error, :not_found} -> {:ok, %Card{ref: ctx.ref}}
      {:error, reason} -> {:failed, launch_reason(reason), from}
    end
  end

  # Restores the replica at `url` into memory, or to the working copy at
  # `path` and opens it, as `mode` says. Answers the handle, where it is
  # (`path`, nil in memory), the mode it flies in, and where the restored
  # state ends; or `{:failed, reason, from}` with nothing of it left. A
  # glider "auto" put in memory that does not fit there is flown from disk.
  defp bring_up(ctx, %{mode: "memory"} = mode, card, url, opts, path, n, from) do
    case Copy.restore_memory(url, opts, ctx.instance) do
      {:ok, restored} ->
        {:ok, Map.merge(restored, %{path: nil, mode: mode})}

      {:error, reason} ->
        if mode.auto and Copy.full?(reason) do
          disk = Copy.decide(ctx.instance, ctx.store, card, disk: true)
          bring_up(ctx, disk, card, url, opts, path, n, from)
        else
          {:failed, {:launch, "restoring #{ctx.ref} into memory: #{text(reason)}"}, from}
        end
    end
  end

  defp bring_up(ctx, mode, _card, url, opts, path, n, from) do
    with :ok <- marker(path, ctx, n),
         {:ok, restored} <- Copy.restore(url, opts, path),
         {:ok, db} <- Copy.open(path, mode) do
      {:ok, Map.merge(restored, %{db: db, path: path, mode: mode})}
    else
      {:error, reason} ->
        _ = Copy.remove(path)
        {:failed, {:launch, "restoring #{ctx.ref}: #{text(reason)}"}, from}
    end
  end

  # A new glider, empty or from a file: flight 1, and its first base in the
  # store before anybody can use it. An adopted file is flown from disk:
  # it is a file.
  defp new(ctx, card, adopt_from) do
    path = working(ctx)

    with {:ok, card} <- own_card(ctx, card),
         :ok <- no_copy(path),
         {:ok, lease} <- take(ctx, create: true) do
      taken(ctx, lease)
      mode = Copy.decide(ctx.instance, ctx.store, card, disk: adopt_from != nil)

      case make(ctx, mode, lease, path, adopt_from) do
        {:ok, db, at} ->
          case first_base(ctx, lease, db, at) do
            {:ok, shipped} -> created(ctx, lease, db, at, card, shipped, mode)
            {:error, reason} -> failed(at, db, reason, nil)
          end

        {:error, reason} ->
          failed(path, nil, reason, nil)
      end
    end
  end

  defp make(ctx, %{mode: "memory"}, _lease, _path, nil) do
    with {:ok, db} <- Copy.open_memory(ctx.instance), do: {:ok, db, nil}
  end

  defp make(ctx, mode, lease, path, adopt_from) do
    with :ok <- marker(path, ctx, lease.n),
         :ok <- adopt(adopt_from, path),
         {:ok, db} <- Copy.open(path, mode) do
      {:ok, db, path}
    end
  end

  defp adopt(nil, _path), do: :ok
  defp adopt(from, path), do: Copy.adopt(from, path)

  defp first_base(ctx, lease, db, path) do
    with :ok <- still_valid(ctx, lease),
         {:ok, url, opts} <- replica(ctx, lease.n),
         {:ok, report} <- Copy.ship(path, db, url, opts) do
      if report.bases > 0,
        do:
          {:ok, %{generation: report.generation, position: report.position, bases: report.bases}},
        else: {:error, "the first shipping pass of #{ctx.ref} sent no base"}
    end
  end

  defp created(ctx, lease, db, path, card, shipped, mode) do
    now = Clock.seconds(ctx.instance.clock)

    case Card.observe(db) do
      {:ok, observation} ->
        card =
          card
          |> Card.put_observation(observation, now)
          |> Map.merge(%{
            created_at: now,
            flight: lease.n,
            generation: shipped.generation,
            position: shipped.position,
            store: ctx.store.name
          })

        {:ok,
         launched(%{db: db, path: path, mode: mode}, card,
           from: nil,
           shipped: shipped,
           changes: [shipped: shipped],
           dirty: false,
           write_card: true
         )}

      {:error, reason} ->
        failed(path, db, reason, nil)
    end
  end

  # R15: a copy left on disk, or a memory flight's replica, whose flight is
  # still the newest one.
  defp carry(ctx, path) do
    with {:ok, marker} <- carried_marker(ctx, path),
         {:ok, current} <- current(ctx),
         :ok <- newest(current, marker),
         {:ok, lease} <-
           take(ctx, carried: true, takeover_own: current.holder == ctx.instance.id) do
      taken(ctx, lease)

      cond do
        lease.n != marker.flight + 1 -> {:failed, {:launch, :superseded}, %{carried: true}}
        Copy.replica?(path) -> carry_replica(ctx, lease, path)
        true -> carry_into(ctx, lease, path, marker)
      end
    end
  end

  defp carried_marker(ctx, path) do
    with true <- is_binary(path) and carriable?(path),
         {:ok, marker} <- Copy.read_marker(path) do
      if marker.store == ctx.store.name and marker.ref == ctx.ref,
        do: {:ok, marker},
        else:
          {:error,
           {:launch,
            "#{path} is a copy of #{marker.ref} in #{marker.store}, not of #{ctx.ref} " <>
              "in #{ctx.store.name}"}}
    else
      {:error, reason} when is_binary(reason) -> {:error, {:launch, reason}}
      _ -> {:error, {:launch, "#{inspect(path)} is not a working copy"}}
    end
  end

  defp carriable?(path) do
    cond do
      String.ends_with?(path, ".gldb") ->
        match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

      Copy.replica?(path) ->
        match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

      true ->
        false
    end
  end

  defp current(ctx) do
    case Lease.current(ctx.store, ctx.ref) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, current} -> {:ok, current}
      {:error, reason} -> {:error, {:launch, reason}}
    end
  end

  defp newest(current, marker) do
    cond do
      current.n == marker.flight ->
        :ok

      current.n > marker.flight ->
        {:error, {:launch, :superseded}}

      true ->
        {:error,
         {:launch,
          "the copy says flight #{marker.flight}, and the store's newest is #{current.n}"}}
    end
  end

  # A copy on disk is flown from disk: it is moved into place, not restored.
  defp carry_into(ctx, lease, path, marker) do
    work = working(ctx)
    from = %{carried: true}

    # A move that fails leaves the copy where it was, and whatever is at the
    # working path is somebody else's: neither is touched.
    case Copy.move(path, work) do
      :ok ->
        with :ok <- marker(work, ctx, lease.n),
             {:ok, card} <- carried_card(ctx),
             mode = Copy.decide(ctx.instance, ctx.store, card, disk: true),
             {:ok, db} <- open_left(work, mode) do
          {:ok,
           launched(%{db: db, path: work, mode: mode}, card,
             from: from,
             shipped: nil,
             changes: [],
             dirty: true,
             write_card: false
           )}
        else
          {:error, reason} ->
            put_back(ctx, work, path, marker)
            {:failed, launch_reason(reason), from}
        end

      {:error, reason} ->
        {:failed, launch_reason(reason), from}
    end
  end

  # A memory flight's replica is restored, into memory or to disk as the
  # card says now, and then removed: its data goes on in this flight, which
  # holds it as log that never shipped. One that cannot be brought up is
  # left as it was.
  defp carry_replica(ctx, lease, path) do
    from = %{carried: true}
    work = working(ctx)

    with :ok <- Copy.replica_whole?(path),
         {:ok, card} <- carried_card(ctx),
         mode = Copy.decide(ctx.instance, ctx.store, card),
         {:ok, up} <- bring_up(ctx, mode, card, path, [], work, lease.n, from) do
      _ = Copy.remove(path)

      {:ok,
       launched(up, card,
         from: from,
         shipped: nil,
         changes: [],
         dirty: true,
         write_card: false
       )}
    else
      {:failed, reason, from} -> {:failed, reason, from}
      {:error, reason} -> {:failed, launch_reason(reason), from}
    end
  end

  # A flight that was killed could not close its handle. Glider lets go of
  # the file when the last process holding the handle's term (the flight,
  # and any caller it lent the handle to) has collected it, and the VM
  # finishes a dead process's cleanup after its monitors have fired. A copy
  # locked by this very OS process is such a handle: collect everybody's
  # garbage, and try again for a while.
  @released_tries 100
  @released_wait 20

  defp open_left(path, mode, tries \\ @released_tries) do
    case Copy.open(path, mode) do
      {:error, reason} = error ->
        if tries > 0 and String.contains?(reason, "locked by pid #{System.pid()}.") do
          Enum.each(Process.list(), &:erlang.garbage_collect/1)
          Process.sleep(@released_wait)
          open_left(path, mode, tries - 1)
        else
          error
        end

      ok ->
        ok
    end
  end

  defp carried_card(ctx) do
    case Store.read_card(ctx.store, ctx.ref) do
      {:ok, card} -> {:ok, card}
      {:error, :not_found} -> {:ok, %Card{ref: ctx.ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A carried copy that could not be flown goes back as it was found.
  defp put_back(ctx, work, path, marker) do
    _ = Copy.write_marker(work, ctx.store, ctx.ref, marker.flight)
    _ = Copy.move(work, path)
    :ok
  end

  # ------------------------------------------------------------------ file stores

  defp file(%{intent: :launch} = ctx) do
    path = working(ctx)

    if File.exists?(path) do
      {card, write_card} =
        case Store.read_card(ctx.store, ctx.ref) do
          {:ok, card} -> {{:ok, card}, false}
          {:error, :not_found} -> {{:ok, %Card{ref: ctx.ref}}, true}
          {:error, reason} -> {{:error, {:launch, reason}}, false}
        end

      with {:ok, card} <- card do
        mode = Copy.decide(ctx.instance, ctx.store, card)

        case Copy.open(path, mode) do
          {:ok, db} -> {:ok, file_launched(db, path, card, write_card, mode)}
          {:error, reason} -> {:error, {:launch, reason}}
        end
      end
    else
      {:error, :not_found}
    end
  end

  defp file(%{intent: {:create, card}} = ctx), do: file_new(ctx, card, nil)
  defp file(%{intent: {:adopt, card, from}} = ctx), do: file_new(ctx, card, from)

  defp file(%{intent: {:carry, _path}}),
    do:
      {:error,
       {:launch, "a glider in a file store is opened where it is; there is no copy to carry"}}

  defp file_new(ctx, card, adopt_from) do
    path = working(ctx)

    with {:ok, card} <- own_card(ctx, card),
         :ok <- no_file(ctx, path) do
      mode = Copy.decide(ctx.instance, ctx.store, card)

      with :ok <- adopt(adopt_from, path),
           {:ok, db} <- Copy.open(path, mode) do
        now = Clock.seconds(ctx.instance.clock)

        case Card.observe(db) do
          {:ok, observation} ->
            card =
              card
              |> Card.put_observation(observation, now)
              |> Map.merge(%{created_at: now, store: ctx.store.name})

            {:ok, file_launched(db, path, card, true, mode)}

          {:error, reason} ->
            Glider.close(db)
            _ = Copy.remove(path)
            {:error, {:launch, reason}}
        end
      else
        {:error, reason} ->
          _ = Copy.remove(path)
          {:error, {:launch, reason}}
      end
    end
  end

  defp no_file(ctx, path) do
    cond do
      Copy.exists?(path) -> {:error, :exists}
      match?({:ok, _}, Store.read_card(ctx.store, ctx.ref)) -> {:error, :exists}
      true -> :ok
    end
  end

  defp file_launched(db, path, card, write_card, mode) do
    launched(%{db: db, path: path, mode: mode}, card,
      from: nil,
      shipped: nil,
      changes: [],
      dirty: false,
      write_card: write_card
    )
  end

  # What every launch answers, measured as it gets up.
  defp launched(up, card, fields) do
    Map.merge(
      %{db: up.db, path: up.path, card: card, mode: up.mode, measured: Copy.measure(up.db)},
      Map.new(fields)
    )
  end

  # ------------------------------------------------------------------ helpers

  defp working(ctx), do: Copy.path(ctx.instance, ctx.store, ctx.ref)

  defp own_card(ctx, %Card{ref: ref} = card) when ref == ctx.ref,
    do: {:ok, %{card | store: ctx.store.name}}

  defp own_card(ctx, _other),
    do: {:error, {:launch, "the card given for #{ctx.ref} is not a card of #{ctx.ref}"}}

  # A copy on disk is never thrown away by a launch: it may hold log that
  # never shipped, and carrying it is somebody's decision (R15).
  defp no_copy(path) do
    if Copy.exists?(path),
      do: {:error, {:launch, {:copy_exists, path}}},
      else: :ok
  end

  defp take(ctx, opts) do
    me = %{id: ctx.instance.id, node: ctx.instance.node, url: ctx.instance.url}

    case Lease.take(ctx.store, ctx.ref, me, ctx.instance.clock, ctx.instance.timing, opts) do
      {:ok, lease} -> {:ok, lease}
      {:error, {:aloft, _lease}} = error -> error
      {:error, reason} when reason in [:not_found, :exists, :no_cas] -> {:error, reason}
      {:error, reason} -> {:error, {:launch, reason}}
    end
  end

  defp taken(ctx, lease), do: send(ctx.flight, {:taken, ctx.tag, lease})

  defp marker(path, ctx, n), do: Copy.write_marker(path, ctx.store, ctx.ref, n)

  defp replica(ctx, n) do
    case Store.replica(ctx.store, Layout.flight_data(ctx.ref, n)) do
      {url, opts} when is_binary(url) -> {:ok, url, opts}
      {:error, reason} -> {:error, "the replica of flight #{n}: #{text(reason)}"}
    end
  end

  # R11: nothing is shipped once the lease has reached its margin.
  defp still_valid(ctx, lease) do
    if Lease.valid?(lease, Clock.now(ctx.instance.clock), ctx.instance.timing),
      do: :ok,
      else: {:error, :lost}
  end

  defp failed(path, db, reason, from) do
    if db, do: Glider.close(db)
    _ = Copy.remove(path)
    {:failed, launch_reason(reason), from}
  end

  defp launch_reason({:launch, _} = reason), do: reason
  defp launch_reason(reason), do: {:launch, reason}

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)
end
