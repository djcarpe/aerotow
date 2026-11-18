defmodule Aerotow.Scan do
  @moduledoc """
  Reading one store's cards into the catalog.

  A scan lists the store's cards (one listing), reads again only the cards
  whose version the listing gives differently from what the catalog
  recorded when it last took them, and makes the catalog's view of that
  store what it found (`Aerotow.Catalog.replace_store_cards/4`): new cards
  are added, changed ones updated, and gliders whose card has gone are
  removed. Gliders aloft here are left as they are; so is a glider whose
  card could not be read this time, which is read again at the next scan.

  A scan that fails, at the listing or at the catalog, leaves the catalog as
  it was.

  It is a telemetry span, `[:aerotow, :scan, :start | :stop | :exception]`,
  with the store's name in its metadata and, when it stops, the
  measurements `seen` (cards listed), `added`, `updated` and `removed`.
  """

  alias Aerotow.{Catalog, Clock, Instance, Store}

  @typedoc "What a scan did."
  @type summary :: %{
          seen: non_neg_integer(),
          read: non_neg_integer(),
          added: non_neg_integer(),
          updated: non_neg_integer(),
          removed: non_neg_integer(),
          conflicts: [Aerotow.Ref.t()]
        }

  @doc "Scans `store` into the instance's catalog."
  @spec run(Instance.t(), Store.t()) :: {:ok, summary()} | {:error, String.t()}
  def run(%Instance{} = instance, %Store{name: name} = store) do
    meta = %{store: name}
    start = System.monotonic_time()

    :telemetry.execute(
      [:aerotow, :scan, :start],
      %{system_time: System.system_time(), monotonic_time: start},
      meta
    )

    result = scan(instance, store)
    stop = System.monotonic_time()

    case result do
      {:ok, summary} ->
        :telemetry.execute(
          [:aerotow, :scan, :stop],
          summary
          |> Map.take([:seen, :added, :updated, :removed])
          |> Map.merge(%{duration: stop - start, monotonic_time: stop}),
          meta
        )

      {:error, reason} ->
        :telemetry.execute(
          [:aerotow, :scan, :exception],
          %{duration: stop - start, monotonic_time: stop},
          Map.merge(meta, %{kind: :error, reason: reason})
        )
    end

    result
  end

  defp scan(instance, store) do
    with {:ok, listed} <- Store.list_cards(store) do
      known = Map.new(Catalog.refs_in(instance.catalog, store.name), &{&1.ref, &1.version})

      {cards, versions} =
        Enum.reduce(listed, {[], %{}}, fn %{ref: ref, version: version}, {cards, versions} ->
          case Map.fetch(known, ref) do
            {:ok, ^version} when version != nil ->
              {cards, Map.put(versions, ref, version)}

            _changed_or_new ->
              case Store.read_card(store, ref) do
                {:ok, card} ->
                  {[card | cards], Map.put(versions, ref, version)}

                {:error, _unreadable} ->
                  # Left as it is, with the version it had, so the next scan
                  # reads it again.
                  {cards, Map.put(versions, ref, Map.get(known, ref))}
              end
          end
        end)

      cards = Enum.reverse(cards)

      with {:ok, result} <-
             Catalog.replace_store_cards(instance.catalog, store.name, cards, versions),
           :ok <- Catalog.touch_store(instance.catalog, store.name, Clock.seconds(instance.clock)) do
        {:ok,
         %{
           seen: length(listed),
           read: length(cards),
           added: result.added,
           updated: result.updated,
           removed: result.removed,
           conflicts: result.conflicts
         }}
      end
    end
  catch
    :exit, reason -> {:error, "the catalog did not answer: #{inspect(reason)}"}
  end
end
