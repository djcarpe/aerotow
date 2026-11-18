defmodule Aerotow.Recovery do
  @moduledoc """
  Carrying a working copy left on disk into the next flight (R15).

  A copy left behind (a VM killed, a catalog that died with its flights, a
  flight lost while its store was away) is worth more than what its store
  has: it may hold log that never shipped. So before anybody restores over
  it, the store is asked about its flight:

    * **still the newest flight**: this instance takes the next flight and
      starts it from the copy instead of restoring (`{:carry, path}`, which
      `Aerotow.Flight` takes). When the newest flight's holder is this
      instance's own id there is no process behind it, and the flight is
      taken over at once instead of after its ttl. The carried copy holds
      log the store lacks, so the new flight ships a whole base at its first
      pass, and from then on every write the copy held is in the store
    * **superseded** (a newer flight exists: somebody else took off) or
      unknown to the store: the copy is set aside in `orphans/` untouched,
      and the launch restores from the store
    * **the copy does not open**: it is set aside with a note of why (an
      orphan already, it is marked so that nobody tries it again)
    * **the store cannot say** (it is unavailable, or failing): the copy is
      left where it is, and asked about again later

  This runs:

    * as the instance starts: `settle/1`, once its stores are made, sets
      aside the copies under `flights/` that cannot be carried, and then
      `sweep/1`, in a task, carries the rest;
    * when a launch finds a copy where its own goes (`decide/4`, through
      `Aerotow.Copies.found/4`), or has an orphan of the glider it launches
      (`intent/3`);
    * on every scan, and when a store becomes available again: `sweep/1`,
      which also carries the orphans whose flight is still the newest, so a
      flight lost while its store was away continues once the store is back
      and nobody took off meanwhile.

  An orphan carried is moved out of `orphans/` into the flight: it is not
  deleted, its data goes on in the new flight.
  """

  require Logger

  alias Aerotow.{Copies, Flight, Instance, Lease, Orphans, Ref, Server, Store}
  alias Aerotow.Flight.Copy

  @released_tries 100
  @released_wait 20
  @ask_timeout 10_000

  @typedoc """
  What `sweep/1` did: how many copies it carried, how many it found could
  not be carried (set aside, or left in `orphans/`), and how many it left
  for later because their store could not say.
  """
  @type summary :: %{
          carried: non_neg_integer(),
          refused: non_neg_integer(),
          left: non_neg_integer()
        }

  # ------------------------------------------------------------------ deciding

  @doc """
  What to do with the copy of `ref` in `store` at `path`, which is under
  `flights/` or `orphans/`: `{:ok, {:carry, path}}`, or `{:ok, :launch}`
  once a copy under `flights/` that cannot be carried has been set aside
  (an orphan stays where it is). `{:error, reason}` when the store cannot
  say what its newest flight is.
  """
  @spec decide(Instance.t(), Store.t(), Ref.t(), Path.t()) ::
          {:ok, Flight.intent()} | {:error, term()}
  def decide(%Instance{} = instance, %Store{} = store, ref, path) do
    case judge(store, ref, path) do
      :carry ->
        case opens(path) do
          :ok -> {:ok, {:carry, path}}
          {:error, reason} -> refuse(instance, path, "it does not open: #{reason}", false)
        end

      # Never carried either, but it may be looked at: nothing is wrong with it.
      {:superseded, why} ->
        refuse(instance, path, why, true)

      {:refuse, why} ->
        refuse(instance, path, why, false)

      {:error, _} = error ->
        error
    end
  end

  # Against the store's newest flight. Reads the store, and the copy's
  # marker; never opens the copy.
  defp judge(store, ref, path) do
    with {:ok, marker} <- marker(path),
         :ok <- same(marker, store, ref) do
      case Lease.current(store, ref) do
        {:ok, nil} ->
          {:refuse, "its store has no flight of #{ref}"}

        {:ok, %Lease{n: n}} when n == marker.flight ->
          :carry

        {:ok, %Lease{n: n}} when n > marker.flight ->
          {:superseded, "flight #{n} superseded its flight #{marker.flight}"}

        {:ok, %Lease{n: n}} ->
          {:refuse, "it says flight #{marker.flight}, and its store's newest is #{n}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp marker(path) do
    case Copy.read_marker(path) do
      {:ok, marker} -> {:ok, marker}
      {:error, reason} -> {:refuse, "its marker cannot be read (#{reason})"}
    end
  end

  defp same(marker, store, ref) do
    if marker.store == store.name and marker.ref == ref,
      do: :ok,
      else: {:refuse, "it is a copy of #{marker.ref} in #{marker.store}"}
  end

  # A copy under flights/ that is not carried goes to orphans/. An orphan
  # stays. Either, when something is wrong with it, is marked so nobody
  # tries it again.
  defp refuse(instance, path, why, sound?) do
    if flights?(instance, path) do
      with :ok <- Copies.set_aside(instance, path, why, carry: sound?), do: {:ok, :launch}
    else
      unless sound?, do: _ = Orphans.note(instance, path, why, carry: false)
      {:ok, :launch}
    end
  end

  defp flights?(%Instance{dir: dir}, path),
    do: String.starts_with?(path, Path.join(dir, "flights") <> "/")

  @doc """
  Whether the copy at `path` opens: a database file, not half restored,
  that glider opens and closes again. A copy locked by this very OS process
  belongs to a flight that was killed and whose handle has not been
  collected yet: everybody's garbage is collected and it is tried again for
  about two seconds.
  """
  @spec opens(Path.t()) :: :ok | {:error, String.t()}
  def opens(path) do
    cond do
      not match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) ->
        {:error, "#{path} is not a database file"}

      File.exists?(path <> ".restoring") ->
        {:error, "a restore into #{path} did not finish"}

      true ->
        with {:ok, db} <- open_left(path, @released_tries) do
          Glider.close(db)
          :ok
        end
    end
  end

  defp open_left(path, tries) do
    case Glider.open(path) do
      {:ok, db} ->
        {:ok, db}

      {:error, reason} ->
        if tries > 0 and String.contains?(reason, "locked by pid #{System.pid()}.") do
          Enum.each(Process.list(), &:erlang.garbage_collect/1)
          Process.sleep(@released_wait)
          open_left(path, tries - 1)
        else
          {:error, reason}
        end
    end
  end

  @doc """
  The intent a launch of `ref` in `store` starts with: `{:carry, path}` for
  an orphan of it whose flight is still the newest and that opens, or
  `:launch`. A copy at the working path is left to the launch, which finds
  it (`Aerotow.Copies.found/4`).
  """
  @spec intent(Instance.t(), Store.t(), Ref.t()) :: Flight.intent()
  def intent(%Instance{} = instance, %Store{} = store, ref) do
    with true <- Store.objects?(store),
         false <- Copy.exists?(Copy.path(instance, store, ref)),
         [orphan | _] <- instance |> Orphans.of(store.name, ref) |> Enum.filter(& &1.carry),
         {:ok, {:carry, _} = carry} <- decide(instance, store, ref, orphan.path) do
      carry
    else
      _ -> :launch
    end
  end

  # ------------------------------------------------------------------ at start

  @doc """
  As the instance starts, once its stores are made: every copy under
  `flights/` of a store that can be reached is judged against it, and the
  ones that cannot be carried are set aside. The ones that can are left for
  `sweep/1`. A store that does not answer within #{div(@ask_timeout, 1000)} s
  leaves its copies where they are.
  """
  @spec settle(Instance.t()) :: :ok
  def settle(%Instance{} = instance) do
    instance
    |> Copies.copies()
    |> Enum.reject(&Copies.flying?(instance, &1))
    |> Task.async_stream(&settle_one(instance, &1),
      timeout: @ask_timeout,
      on_timeout: :kill_task,
      max_concurrency: 8,
      ordered: false
    )
    |> Stream.run()

    Copies.tidy(instance)
  end

  defp settle_one(instance, path) do
    with {:ok, marker} <- Copy.read_marker(path),
         {:ok, store} <- Server.store(instance, marker.store),
         true <- Store.objects?(store) do
      _ = decide(instance, store, marker.ref, path)
    end

    :ok
  end

  # ------------------------------------------------------------------ carrying

  @doc """
  Carries what can be carried: each copy under `flights/` whose glider is
  not aloft here, and for each glider not aloft here its newest orphan,
  when the copy's flight is still the newest in a store that can be
  reached. A copy that cannot be carried is set aside as `decide/4` says;
  one whose store cannot say is left for the next sweep.
  """
  @spec sweep(Instance.t()) :: summary()
  def sweep(%Instance{} = instance) do
    left =
      instance
      |> Copies.copies()
      |> Enum.reject(&Copies.flying?(instance, &1))

    orphans =
      instance
      |> Orphans.list()
      |> Enum.filter(&(&1.carry and &1.flight != nil))
      |> Enum.group_by(&{&1.store, &1.ref})
      |> Enum.map(fn {_glider, orphans} -> Enum.max_by(orphans, & &1.flight) end)
      |> Enum.map(& &1.path)

    summary =
      Enum.reduce(left ++ orphans, %{carried: 0, refused: 0, left: 0}, fn path, acc ->
        key = sweep_one(instance, path)
        Map.update!(acc, key, &(&1 + 1))
      end)

    Copies.tidy(instance)
    summary
  end

  defp sweep_one(instance, path) do
    with {:ok, marker} <- Copy.read_marker(path),
         [] <- Registry.lookup(instance.registry, marker.ref),
         {:ok, store} <- Server.store(instance, marker.store),
         true <- Store.objects?(store),
         # An orphan waits while a copy is at its working path: that one is decided first.
         true <-
           flights?(instance, path) or not Copy.exists?(Copy.path(instance, store, marker.ref)),
         {:ok, {:carry, ^path}} <- decide(instance, store, marker.ref, path) do
      case carry(instance, store, marker.ref, path) do
        {:ok, _pid} ->
          :carried

        {:error, reason} ->
          Logger.warning(
            "aerotow: the copy of #{marker.ref} at #{path} could not be carried: #{inspect(reason)}"
          )

          :left
      end
    else
      {:ok, :launch} -> :refused
      _ -> :left
    end
  end

  @doc """
  Starts a flight of `ref` in `store` from the copy at `path`, with room
  made for it, and waits until it is up. Once an orphan is carried, its
  note goes.
  """
  @spec carry(Instance.t(), Store.t(), Ref.t(), Path.t()) :: {:ok, pid()} | {:error, term()}
  def carry(%Instance{} = instance, %Store{} = store, ref, path) do
    with {:ok, token} <- Server.room(instance, ref) do
      result =
        Flight.start(
          instance: instance,
          store: store,
          ref: ref,
          intent: {:carry, path},
          pin: false
        )

      Server.done(instance, token)
      if match?({:ok, _}, result), do: carried(path)
      result
    end
  end

  @doc "Tidies after a copy at `path` was carried: an orphan's note goes."
  @spec carried(Path.t()) :: :ok
  def carried(path), do: Orphans.forget_note(path)
end
