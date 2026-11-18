defmodule Aerotow.Retention do
  @moduledoc """
  Deleting what a store no longer needs to keep, done by whoever holds a
  glider's current flight.

  Each flight ships into its own directory, so a glider's store fills with
  the directories of flights long over. Once a newer flight has a whole
  base in the store, an older flight is needed by nobody: a launch restores
  from the newest flight with a whole base (R12). So for every glider aloft
  here, a pass

    * deletes the older flights' records and directories, below the newest
      flight with a whole base, once they landed (or, for one that never
      landed, ran out) more than `retention` ago, on the instance's clock
      (`Aerotow.Lease.retire/5`). The newest flight with a whole base is
      never deleted, nor anything above it, nor any other glider's flights;
    * trims within the current flight what glider's own retention says it
      no longer needs: bases older than `retention` but the newest, and the
      log below the oldest base kept
      (`Glider.Replication.enforce_retention/3`, on glider's own clock).

  Only the holder does either: a pass runs inside a checkout of the flight,
  which the flight refuses unless it is aloft and its lease holds. A glider
  that is not aloft here is not touched, whatever its store holds.

  The server runs a pass every `min(retention, 1 hour)`, at least a minute
  apart; `run/1` runs one now.

  ## Telemetry

    * `[:aerotow, :retention, :retired]` - `%{flights: n}`: older flights
      deleted, with `ref`, `store` and `flight` (the current one)
    * `[:aerotow, :retention, :trimmed]` - `%{objects: n}`: objects glider's
      retention deleted within the current flight
    * `[:aerotow, :retention, :failed]` - with `reason`, when either failed
  """

  require Logger

  alias Aerotow.{Flight, Instance, Lease, Server, Store}
  alias Aerotow.Flight.{Copy, Launch}
  alias Aerotow.Store.Layout

  @hour 3_600_000
  @minute 60_000

  @typedoc "What one pass did for one glider."
  @type result :: %{
          ref: String.t(),
          store: String.t(),
          flight: pos_integer(),
          retired: non_neg_integer() | {:error, term()},
          trimmed: non_neg_integer() | {:error, term()}
        }

  @doc "How often the server runs a pass, for an instance's `retention`."
  @spec interval(Instance.t()) :: pos_integer()
  def interval(%Instance{retention: retention}), do: retention |> min(@hour) |> max(@minute)

  @doc """
  One pass over every glider aloft here, now. Answers what it did for each
  glider whose flight let it in; a flight that is launching, landing or
  lost is skipped.
  """
  @spec run(Instance.t()) :: {:ok, [result()]}
  def run(%Instance{} = instance) do
    results =
      instance.registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.flat_map(fn {ref, pid, store_name} ->
        with {:ok, store} <- Server.store(instance, store_name),
             true <- Store.objects?(store),
             {:ok, result} <- one(instance, store, ref, pid) do
          [result]
        else
          _ -> []
        end
      end)

    {:ok, results}
  end

  # Inside a read checkout: the flight lends its handle only while it is
  # aloft and its lease holds, so only the holder runs this.
  defp one(instance, store, ref, pid) do
    info = safely(fn -> Flight.info(pid) end)

    with %{state: :aloft, flight: n} when is_integer(n) <- info,
         {:ok, result} <-
           Flight.run(pid, :read, fn _db -> pass(instance, store, ref, n) end,
             timeout: instance.sync_timeout
           ) do
      {:ok, result}
    else
      _ -> :skipped
    end
  end

  defp pass(instance, store, ref, n) do
    meta = %{ref: ref, store: store.name, flight: n}

    retired =
      case Lease.retire(store, ref, instance.clock, instance.retention, &Launch.whole_base?/2) do
        {:ok, count} ->
          emit(:retired, %{flights: count}, meta)
          count

        {:error, reason} ->
          failed(meta, :retire, reason)
      end

    trimmed =
      with {url, opts} when is_binary(url) <- Store.replica(store, Layout.flight_data(ref, n)),
           opts = Keyword.put(opts, :retention, max(div(instance.retention, 1000), 1)),
           {:ok, count} <-
             Glider.Replication.enforce_retention(Copy.path(instance, store, ref), url, opts) do
        emit(:trimmed, %{objects: count}, meta)
        count
      else
        {:error, reason} -> failed(meta, :trim, reason)
      end

    %{ref: ref, store: store.name, flight: n, retired: retired, trimmed: trimmed}
  end

  defp failed(meta, step, reason) do
    Logger.warning(
      "aerotow: retention for #{meta.ref} in #{meta.store} (#{step}) failed: #{text(reason)}"
    )

    emit(:failed, %{}, Map.merge(meta, %{step: step, reason: reason}))
    {:error, reason}
  end

  defp emit(event, measurements, meta),
    do: :telemetry.execute([:aerotow, :retention, event], measurements, meta)

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> nil
  end

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)
end
