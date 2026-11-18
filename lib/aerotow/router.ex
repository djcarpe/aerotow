defmodule Aerotow.Router do
  @moduledoc """
  Where a glider is, and so where a statement for it runs. This is the one
  place that decides.

      1. aloft here                       → here
      2. home is a peer store             → the peer (`Aerotow.Forward`)
      3. home is a file store             → launch here (open in place)
      4. home is a dir or s3 store
         current flight active, not ours  → aloft elsewhere, with its holder,
                                            to forward to (`Aerotow.Forward`)
         otherwise                        → launch here

  The home comes from the catalog. A ref the catalog does not know is
  looked for in each store's cards, in the order the stores were given,
  before the answer is `:not_found`; a card found there is put into the
  catalog, and routing carries on (R3).

  Everything is read without waiting on a process that may be busy: the
  registry, the instance's table of stores, the catalog's handle. The one
  question that goes to a store is the current flight, for a glider homed in
  a `dir` or `s3` store that is not aloft here.

  A flight of our own that is active with no process behind it (a flight
  that died, or one this instance held before it restarted) is not
  "elsewhere": a launch here takes it over (`Aerotow.Lease.take/6` with
  `takeover_own: true`).
  """

  alias Aerotow.{Card, Catalog, Clock, Instance, Lease, Ref, Server, Store}

  @typedoc "Who holds a glider that is aloft on another instance, from its flight record."
  @type holder :: %{
          holder: String.t(),
          node: String.t() | nil,
          url: String.t() | nil,
          flight: pos_integer()
        }

  @typedoc "Where a glider is."
  @type place ::
          {:here, pid()}
          | {:peer, Store.t()}
          | {:elsewhere, holder()}
          | {:launch, Store.t()}

  @typedoc """
  Why a glider could not be placed:

    * `:not_found` - no store has a card for it
    * `:purging` - this instance is deleting it from its store
    * `{:store_unavailable, name, reason}` - its home is a store this
      instance cannot reach now, or does not have
    * a string, for a store that failed while it was asked
  """
  @type reason ::
          :not_found | :purging | {:store_unavailable, String.t(), String.t()} | String.t()

  @doc "Where `ref` is: here, on a peer, aloft elsewhere, or to be launched here."
  @spec locate(Instance.t(), Ref.t()) :: {:ok, place()} | {:error, reason()}
  def locate(%Instance{} = instance, ref) do
    with {:ok, ref} <- parse(ref),
         :ok <- not_purging(instance, ref) do
      case Registry.lookup(instance.registry, ref) do
        [{pid, _store} | _] -> {:ok, {:here, pid}}
        [] -> from_home(instance, ref)
      end
    end
  end

  @doc """
  Where the glider is open for a call that runs where it is open:
  `{:here, pid}`, `{:launch, store}`, or why it is not open here. A glider
  homed in a peer store is `{:error, {:runs_on_peer, store}}`; one aloft on
  another instance is `{:error, {:aloft_elsewhere, holder}}`. A call that
  can be sent there instead is, by `Aerotow` with `Aerotow.Forward`.
  """
  @spec route(Instance.t(), Ref.t()) ::
          {:ok, {:here, pid()} | {:launch, Store.t()}}
          | {:error, reason() | {:runs_on_peer, String.t()} | {:aloft_elsewhere, holder()}}
  def route(instance, ref) do
    case locate(instance, ref) do
      {:ok, {:peer, store}} -> {:error, {:runs_on_peer, store.name}}
      {:ok, {:elsewhere, holder}} -> {:error, {:aloft_elsewhere, holder}}
      other -> other
    end
  end

  @doc "The holder of a flight record, as `{:aloft_elsewhere, holder}` gives it."
  @spec holder(Lease.t()) :: holder()
  def holder(%Lease{} = lease),
    do: %{holder: lease.holder, node: lease.node, url: lease.url, flight: lease.n}

  @doc """
  The card of `ref`: the catalog's, or, on a miss, the first card any store
  has for it, in the order the stores were given, which is then put into the
  catalog (R3).
  """
  @spec card(Instance.t(), Ref.t()) :: {:ok, Card.t()} | {:error, reason()}
  def card(%Instance{} = instance, ref) do
    with {:ok, ref} <- parse(ref) do
      case Catalog.card(instance.catalog, ref) do
        {:ok, card} -> {:ok, card}
        {:error, :not_found} -> look_up(instance, ref)
      end
    end
  end

  defp parse(ref) do
    case Ref.parse(ref) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, reason}
    end
  end

  defp not_purging(instance, ref) do
    if Server.purging?(instance, ref), do: {:error, :purging}, else: :ok
  end

  defp from_home(instance, ref) do
    with {:ok, card} <- card(instance, ref),
         {:ok, store} <- Server.store(instance, card.store) do
      place(instance, store, ref)
    end
  end

  defp place(_instance, %Store{kind: :peer} = store, _ref), do: {:ok, {:peer, store}}
  defp place(_instance, %Store{kind: :file} = store, _ref), do: {:ok, {:launch, store}}

  defp place(instance, store, ref) do
    case Lease.current(store, ref) do
      {:ok, %Lease{} = lease} ->
        now = Clock.now(instance.clock)

        if Lease.active?(lease, now, instance.timing) and lease.holder != instance.id,
          do: {:ok, {:elsewhere, holder(lease)}},
          else: {:ok, {:launch, store}}

      {:ok, nil} ->
        {:ok, {:launch, store}}

      {:error, reason} ->
        {:error, text(reason)}
    end
  end

  # R3: a ref the catalog has not seen is read from each store's cards.
  defp look_up(instance, ref) do
    instance
    |> Server.available_stores()
    |> Enum.reduce_while({:error, :not_found}, fn store, miss ->
      case Store.read_card(store, ref) do
        {:ok, card} -> {:halt, {:ok, %{card | store: store.name, aloft: false}}}
        {:error, :not_found} -> {:cont, miss}
        {:error, _unreadable} -> {:cont, miss}
      end
    end)
    |> case do
      {:ok, card} ->
        # Put so the next call finds it at once. A catalog that will not take
        # it still lets this call go on.
        _ = Catalog.put_card(instance.catalog, card)
        {:ok, card}

      miss ->
        miss
    end
  end

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)
end
