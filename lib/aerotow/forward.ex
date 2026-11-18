defmodule Aerotow.Forward do
  @moduledoc """
  Sending a call to the aerotow that answers for a glider, and answering
  one sent here.

  Two kinds of instance answer for a glider this one does not have open:

    * a **peer**: the glider is homed in a `peer` store, another deployment
      reached over HTTP (`Aerotow.Store.Peer`). The call goes to it.
    * a **holder**: the glider is homed in a `dir` or `s3` store and
      another instance holds its flight. The call goes to the holder, by
      the first of these that the flight record allows:
        1. Erlang distribution, when the record's `node` is the name of a
           connected node (compared as text with `Node.list/0`, never made
           an atom: R16) that runs an aerotow of this instance's name;
        2. HTTP, when the record's `url` is the url of a peer store this
           instance has, and so a token for it;
        3. otherwise `{:error, {:aloft_elsewhere, holder}}`, as without
           this module.

  ## Hops

  A forwarded call carries how many times it has been forwarded, counting
  the forward that carries it. The first forward is hop 1; a call that would
  go out as hop 4 is refused here with `{:error, :too_many_hops}`, and
  one that arrives claiming more than 3 is refused by `serve/4`. So two
  instances that each believe the other has a glider (a stale catalog, a
  record that has moved on) answer `:too_many_hops` after three hops
  instead of passing the call back and forth.

  ## The receiving side

  `serve/4` runs a request here, through the same public functions a local
  caller uses, so the receiver applies its own rules: a `query` is checked
  by its `Aerotow.Statement`, a `run` or `batch` refuses `BEGIN`, `COMMIT`
  and `ROLLBACK`, and `max_rows` and `max_bytes` are bounded by the
  receiver's limits whatever the sender asked for. Nothing runs that would
  be refused from a local caller.

  ## Failures

  A peer or holder that cannot be asked is `{:peer_unavailable, where,
  reason}` (`where` is the peer store's name, or the node's). A write sent
  whose answer did not arrive is `{:outcome_unknown, where, reason}`: it
  may or may not have been applied, and it is not sent again. Reads are
  tried again a bounded number of times (`Aerotow.Store.Peer`).

  ## Telemetry

  Each forward is a span, `[:aerotow, :forward, :start | :stop |
  :exception]`, with `ref`, `op` and `via` (`:distribution` or `:http`)
  in its metadata, and `result` (`:ok` or `:error`) when it stops.
  """

  alias Aerotow.{Card, Catalog, Instance, Router, Server, Store, Wire}
  alias Aerotow.Store.Peer

  @max_hops 3
  @hops {__MODULE__, :hops}
  @max_rows 10_000
  @max_bytes 8 * 1024 * 1024

  @doc "The most hops a call is forwarded."
  @spec max_hops() :: pos_integer()
  def max_hops, do: @max_hops

  @doc """
  The hop the next forward from this process would be: one more than the
  hop of the call being served here, or 1 for a call that started here.
  `{:error, :too_many_hops}` past #{@max_hops}.
  """
  @spec next_hop() :: {:ok, pos_integer()} | {:error, :too_many_hops}
  def next_hop do
    hop = Process.get(@hops, 0) + 1
    if hop > @max_hops, do: {:error, :too_many_hops}, else: {:ok, hop}
  end

  # ------------------------------------------------------------------ sending

  @doc """
  Sends `request` to the peer store `store` and answers as the peer did.

  What a peer answers about its cards is put into this catalog, homed in
  `store`: the card `card`, `create` and `update` answer, and the
  forgetting of one `delete` removed.
  """
  @spec to_peer(Instance.t(), Store.t(), Wire.request()) :: {:ok, term()} | {:error, term()}
  def to_peer(%Instance{} = instance, %Store{kind: :peer} = store, request) do
    with {:ok, hop} <- next_hop() do
      span(request, :http, fn -> Peer.call(store, request, hop) end)
      |> observe(instance, store, request)
    end
  end

  def to_peer(_instance, %Store{name: name}, _request),
    do: {:error, {:peer_unavailable, name, "it is not a peer store"}}

  defp observe({:ok, %Card{} = card} = ok, instance, store, {op, _, _})
       when op in [:create, :update] do
    _ = Catalog.put_card(instance.catalog, %{card | store: store.name, aloft: false})
    ok
  end

  defp observe({:ok, %Card{} = card} = ok, instance, store, {:card, _}) do
    _ = Catalog.put_card(instance.catalog, %{card | store: store.name, aloft: false})
    ok
  end

  defp observe({:ok, :ok} = ok, instance, _store, {:delete, ref, _opts}) do
    _ = Catalog.delete_card(instance.catalog, ref)
    ok
  end

  defp observe(result, _instance, _store, _request), do: result

  @doc """
  Sends `request` to the instance that holds a glider's flight (see the
  moduledoc for how), or answers `{:error, {:aloft_elsewhere, holder}}`
  when it cannot be reached either way.
  """
  @spec to_holder(Instance.t(), Router.holder(), Wire.request()) ::
          {:ok, term()} | {:error, term()}
  def to_holder(%Instance{} = instance, holder, request) do
    with {:ok, hop} <- next_hop() do
      case over_distribution(instance, holder, request, hop) do
        :no_route -> over_http(instance, holder, request, hop)
        answered -> answered
      end
    end
  end

  defp over_distribution(_instance, %{node: nil}, _request, _hop), do: :no_route

  defp over_distribution(instance, %{node: name}, request, hop) when is_binary(name) do
    case Enum.find(Node.list(), &(Atom.to_string(&1) == name)) do
      nil ->
        :no_route

      node ->
        result =
          span(request, :distribution, fn -> erpc(instance, node, request, hop) end)

        # An instance of this name not running there is not a route; HTTP
        # may still be one.
        if result == {:error, :no_route}, do: :no_route, else: result
    end
  end

  defp over_distribution(_instance, _holder, _request, _hop), do: :no_route

  defp erpc(instance, node, request, hop) do
    case :erpc.call(
           node,
           __MODULE__,
           :serve,
           [instance.name, request, hop, []],
           timeout(instance)
         ) do
      {:error, :not_running} -> {:error, :no_route}
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, "#{node} answered #{inspect(other, limit: 5)}"}
    end
  catch
    :error, {:erpc, :noconnection} ->
      {:error, :no_route}

    :error, {:exception, :undef, _} ->
      {:error, :no_route}

    :error, {:erpc, :timeout} ->
      lost(request, Atom.to_string(node), "no answer within #{timeout(instance)} ms")

    kind, reason ->
      lost(
        request,
        Atom.to_string(node),
        "the call failed there: #{inspect({kind, reason}, limit: 8)}"
      )
  end

  defp timeout(instance), do: instance.launch_timeout

  defp lost(request, where, why) do
    if Wire.read?(elem(request, 0)),
      do: {:error, {:peer_unavailable, where, why}},
      else:
        {:error, {:outcome_unknown, where, why <> "; the write may or may not have been applied"}}
  end

  defp over_http(instance, holder, request, hop) do
    case holder do
      %{url: url} when is_binary(url) ->
        case Enum.find(
               Server.available_stores(instance),
               &(&1.kind == :peer and same?(&1.url, url))
             ) do
          nil -> {:error, {:aloft_elsewhere, holder}}
          store -> span(request, :http, fn -> Peer.call(store, request, hop) end)
        end

      _ ->
        {:error, {:aloft_elsewhere, holder}}
    end
  end

  defp same?(a, b), do: String.trim_trailing(a, "/") == String.trim_trailing(b, "/")

  defp span(request, via, fun) do
    meta = %{ref: Wire.ref(request), op: elem(request, 0), via: via}

    :telemetry.span([:aerotow, :forward], meta, fn ->
      result = fun.()
      {result, Map.put(meta, :result, if(match?({:ok, _}, result), do: :ok, else: :error))}
    end)
  end

  # ------------------------------------------------------------------ serving

  @doc """
  Runs a request sent from another instance, here, as hop `hop`: through
  the public functions of `Aerotow`, so with this instance's own rules.
  Answers `{:ok, value}` or `{:error, reason}`.

  `limits` are the receiver's: `max_rows:` (#{@max_rows}) and `max_bytes:`
  (#{@max_bytes}) bound a query whatever it asked for. A `gliders` page
  lists only gliders homed in this instance's own stores, not those it
  knows through its peers, so two aerotows that are each other's peers do
  not hand each other's gliders back.
  """
  @spec serve(atom(), Wire.request(), non_neg_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def serve(tow, request, hop, limits \\ [])

  def serve(_tow, _request, hop, _limits) when is_integer(hop) and hop > @max_hops,
    do: {:error, :too_many_hops}

  def serve(tow, request, hop, limits) when is_atom(tow) and is_integer(hop) and hop >= 0 do
    previous = Process.put(@hops, hop)

    try do
      tow |> run(bound(request, limits)) |> answer()
    after
      if previous, do: Process.put(@hops, previous), else: Process.delete(@hops)
    end
  end

  def serve(_tow, _request, _hop, _limits), do: {:error, "not a forwarded call"}

  defp bound({:query, ref, cypher, params, opts}, limits) do
    rows = Keyword.get(limits, :max_rows, @max_rows)
    bytes = Keyword.get(limits, :max_bytes, @max_bytes)

    opts =
      opts
      |> Keyword.put(:max_rows, min(Keyword.get(opts, :max_rows, rows), rows))
      |> Keyword.put(:max_bytes, min(Keyword.get(opts, :max_bytes, bytes), bytes))

    {:query, ref, cypher, params, opts}
  end

  defp bound(request, _limits), do: request

  defp run(tow, {:query, ref, cypher, params, opts}),
    do: Aerotow.query(tow, ref, cypher, params, opts)

  defp run(tow, {:run, ref, cypher, params, opts}),
    do: Aerotow.run(tow, ref, cypher, params, opts)

  defp run(tow, {:write_batch, ref, statements, opts}),
    do: Aerotow.write_batch(tow, ref, statements, opts)

  defp run(tow, {:context, ref, opts}), do: Aerotow.context(tow, ref, opts)
  defp run(tow, {:schema, ref}), do: Aerotow.schema(tow, ref)
  defp run(tow, {:stats, ref}), do: Aerotow.stats(tow, ref)
  defp run(tow, {:card, ref}), do: Aerotow.card(tow, ref)
  defp run(tow, {:create, ref, opts}), do: Aerotow.create(tow, ref, opts)
  defp run(tow, {:update, ref, changes}), do: Aerotow.update(tow, ref, changes)
  defp run(tow, {:delete, ref, opts}), do: Aerotow.delete(tow, ref, opts)
  defp run(tow, {:find, cypher, params}), do: Aerotow.find(tow, cypher, params)
  defp run(tow, {:search, text, opts}), do: Aerotow.search(tow, text, opts)

  defp run(tow, {:gliders, opts}) do
    with {:ok, instance} <- Instance.fetch(tow),
         {:ok, page} <- Aerotow.gliders(tow, opts) do
      peers = for %{kind: :peer, name: name} <- Server.stores(instance), do: name
      {:ok, %{page | gliders: Enum.reject(page.gliders, &(&1.store in peers))}}
    end
  end

  defp run(_tow, request), do: {:error, "not a request: #{inspect(request, limit: 5)}"}

  defp answer(:ok), do: {:ok, :ok}
  defp answer({:ok, _} = ok), do: ok
  defp answer({:error, _} = error), do: error
  defp answer(other), do: {:error, {:unexpected, other}}
end
