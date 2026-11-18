defmodule Aerotow.Purge do
  @moduledoc """
  Deleting a glider from its store: `Aerotow.delete(tow, ref, purge: true)`.

  In a `dir` or `s3` store the glider is taken first, so that no other
  instance can take it while it is half deleted:

    1. a flight of it here is landed;
    2. the next flight is taken (`Aerotow.Lease.take/6`), with no process
       behind it: while this instance holds it, every other taker finds the
       glider aloft here and writes nothing (R9);
    3. the card is deleted, then every object under the glider's flights
       (records and what each flight shipped), except the record of the
       flight just taken; the lease is renewed as it goes, and a purge that
       finds it lost stops and says so, and can be run again;
    4. the record of that flight is deleted last, and the glider is gone
       from the catalog.

  Another instance that asks for the glider afterwards finds no card and no
  flight: `:not_found`. While this instance purges a ref, a statement for it
  here is `{:error, :purging}`.

  In a `file` store the glider's lock is the guard: it is taken (the file is
  opened), released, and the database, glider's files beside it and the card
  are deleted. Another instance that opens the file between the two is not
  stopped: a file store is for gliders that live on one machine.
  """

  alias Aerotow.{Catalog, Clock, Flight, Instance, Lease, Router, Server, Store}
  alias Aerotow.Store.Layout

  @doc "Purges `ref`, as the moduledoc says."
  @spec run(Instance.t(), Aerotow.Ref.t()) :: :ok | {:error, term()}
  def run(%Instance{} = instance, ref) do
    with {:ok, card} <- Router.card(instance, ref),
         {:ok, store} <- Server.store(instance, card.store),
         :ok <- purgeable(store),
         :ok <- Server.purge(instance, card.ref) do
      try do
        with :ok <- land_here(instance, card.ref),
             :ok <- purge(instance, store, card.ref) do
          _ = Catalog.delete_card(instance.catalog, card.ref)
          :ok
        end
      after
        Server.unpurge(instance, card.ref)
      end
    end
  end

  defp purgeable(%Store{kind: :peer}), do: {:error, :peer_not_supported}
  defp purgeable(_store), do: :ok

  defp land_here(instance, ref) do
    case Registry.lookup(instance.registry, ref) do
      [{pid, _store}] ->
        case Flight.land(pid, instance.sync_timeout) do
          :ok -> :ok
          {:error, :noproc} -> :ok
          {:error, reason} -> {:error, reason}
        end

      [] ->
        :ok
    end
  end

  defp purge(_instance, %Store{kind: :file} = store, ref) do
    path = Store.File.path(store, ref)

    if File.exists?(path) do
      case Glider.open(path) do
        {:ok, db} ->
          Glider.close(db)
          Store.purge(store, ref)

        {:error, reason} ->
          {:error, "#{ref} is open elsewhere and was not purged: #{reason}"}
      end
    else
      Store.purge(store, ref)
    end
  end

  defp purge(instance, store, ref) do
    me = %{id: instance.id, node: instance.node, url: instance.url}

    case Lease.take(store, ref, me, instance.clock, instance.timing, takeover_own: true) do
      {:ok, lease} ->
        with {:ok, lease} <- delete_all(instance, store, ref, lease) do
          delete(store, Layout.flight_record(ref, lease.n))
        end

      {:error, :not_found} ->
        # No flight was ever taken: only the card is there, if anything.
        with {:ok, _} <- delete_all(instance, store, ref, nil), do: :ok

      {:error, {:aloft, lease}} ->
        {:error, {:aloft_elsewhere, Router.holder(lease)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_all(instance, store, ref, lease) do
    own = lease && Layout.flight_record(ref, lease.n)

    with :ok <- Store.delete_card(store, ref),
         {:ok, %{objects: objects}} <- Store.list(store, Layout.flights_prefix(ref)) do
      objects
      |> Enum.map(& &1.key)
      |> Enum.reject(&(&1 == own))
      |> Enum.reduce_while({:ok, lease}, fn key, {:ok, lease} ->
        with {:ok, lease} <- hold(instance, store, lease),
             :ok <- delete(store, key) do
          {:cont, {:ok, lease}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  # The lease is renewed once a third of it has gone, as a flight would.
  defp hold(_instance, _store, nil), do: {:ok, nil}

  defp hold(instance, store, lease) do
    now = Clock.now(instance.clock)
    ttl = instance.timing.ttl

    cond do
      not Lease.valid?(lease, now, instance.timing) ->
        {:error, "the purge of #{lease.ref} lost its flight part way; run it again"}

      now >= lease.expires_at - ttl + div(ttl, 3) ->
        case Lease.renew(store, lease, instance.clock, instance.timing) do
          {:ok, lease} ->
            {:ok, lease}

          {:error, :lost} ->
            {:error, "the purge of #{lease.ref} lost its flight part way; run it again"}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:ok, lease}
    end
  end

  defp delete(store, key) do
    case Store.delete(store, key) do
      :ok -> :ok
      {:error, reason} -> {:error, "deleting #{key}: #{inspect(reason)}"}
    end
  end
end
