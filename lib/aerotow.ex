defmodule Aerotow do
  @moduledoc """
  One interface over many [glider](https://github.com/djcarpe/glider) graphs.

  An aerotow is the powered aircraft that tows a glider into the air and lets
  it go. This library knows where each glider is kept, launches it when
  somebody needs it, and puts it back when they are done:

    * a **catalog**: a graph of metadata, itself a glider, with a node for
      every glider and every store. Finding a glider is a query over it
    * **stores**: a directory of live files, a directory or an S3 bucket of
      replicas, or another aerotow reached over HTTP
    * **one interface**: `query/5`, `run/5`, `context/3` do the same thing
      wherever a glider is kept

  Every glider stays an independent database with its own single writer.
  Aerotow never merges two of them; it routes.

  The design, and the rules the code is built against, are in
  [docs/DESIGN.md](docs/DESIGN.md).

  ## Starting one

      children = [
        {Aerotow,
         name: MyApp.Aerotow,
         dir: "/var/lib/aerotow",
         stores: [
           {"disk", "/var/lib/gliders", kind: :file},
           {"assets", "s3://graphs/gliders", endpoint: "http://minio.internal:9000",
                      access_key_id: key, secret_access_key: secret}
         ],
         default_store: "assets"}
      ]

  `name:` is what every function here takes first, as `tow`. `dir:` is the
  working directory, which one instance has to itself: a second instance on
  the same `dir`, in this VM or another, does not start. The other options
  are in `Aerotow.Instance`. A store that cannot be reached as the instance
  starts does not stop it: it is tried again, and calls that need it answer
  `{:error, {:store_unavailable, name, reason}}` until it answers.

  ## Where a statement runs

  `Aerotow.Router` decides: on the flight here when the glider is aloft
  here; launched here when it is hangared; forwarded to the peer when the
  glider is homed in a `peer` store; forwarded to the holder when another
  instance holds its flight, and refused with `{:error, {:aloft_elsewhere,
  holder}}` when the holder cannot be reached (`Aerotow.Forward`). A
  statement that runs here runs in the calling process, with the handle the
  flight lends it, so a long query never holds up anything else.

  `query/5`, `run/5`, `write_batch/4`, `context/3`, `schema/2`, `stats/2`,
  `card/2`, `update/3`, `delete/3` and `create/3` are forwarded that way.
  `checkout/4`, `launch/3` and `describe/2` run here only: for a glider
  homed in a peer they are `{:error, {:runs_on_peer, store}}`, and for one
  aloft elsewhere `{:error, {:aloft_elsewhere, holder}}`.

  Results are glider_ex's own: `{:ok, %Glider.Result{}}` from `query/5`,
  `{:ok, touched}` from `run/5`.
  """

  alias Aerotow.{
    Card,
    Catalog,
    Copies,
    Flight,
    Forward,
    Instance,
    Options,
    Purge,
    Ref,
    Router,
    Server,
    Statement,
    Store
  }

  @typedoc "An instance's name: the `name:` it was started with."
  @type tow :: atom()

  @typedoc """
  Why a call was refused. These are what code branches on:

    * `:not_running` - no instance of that name is running
    * `:not_found` - no store has a glider of that ref
    * `:exists` - `create/3` or `adopt/4` of a ref that is already known
      somewhere a store can tell, or `add_store/4` of a name in use
    * `:not_aloft` - `land/2` or `sync/2` of a glider not aloft here
    * `{:aloft_elsewhere, holder}` - another instance holds the glider's
      flight; `holder` is `%{holder: id, node: node, url: url, flight: n}`
    * `{:runs_on_peer, store}` - the glider is homed in the peer store
      `store`, and the call runs only where the glider is open
      (`checkout/4`, `launch/3`, `describe/2`): it runs there
    * `:too_many_hops` - the call was forwarded more than three times
      (`Aerotow.Forward`)
    * `{:peer_unavailable, where, reason}` - the peer or holder a call was
      forwarded to could not answer it (`where` is a peer store's name or a
      node's)
    * `{:outcome_unknown, where, reason}` - a write was forwarded and its
      answer was lost: it may or may not have been applied
    * `{:store_unavailable, name, reason}` - its store cannot be reached now
    * `:too_many_aloft` - there is no room for another flight here, and no
      flight could land to make it
    * `:purging` - this instance is purging the glider
    * `:lost` - the flight lost its lease while the call was under way
    * `:landing` - the flight was on its way down and stayed so
    * `:timeout`, `:no_cas`, `{:launch, reason}` - as `Aerotow.Flight`
      gives them

  Anything a person reads, such as a statement refused for being a write or
  an option that is not one, is a string.
  """
  @type reason ::
          :not_running
          | :not_found
          | :exists
          | :not_aloft
          | {:aloft_elsewhere, Router.holder()}
          | {:runs_on_peer, String.t()}
          | :too_many_hops
          | {:peer_unavailable, String.t(), String.t()}
          | {:outcome_unknown, String.t(), String.t()}
          | {:store_unavailable, String.t(), String.t()}
          | :too_many_aloft
          | :purging
          | :lost
          | :landing
          | :timeout
          | :no_cas
          | {:launch, term()}
          | String.t()

  @typedoc "Where a glider is, as `where/2` says."
  @type place :: :here | {:elsewhere, Router.holder()} | {:peer, String.t()} | :hangared

  @tries 3
  @query_options [:max_rows, :max_bytes, :graph, :timeout]
  @run_options [:sync, :timeout]
  @max_batch 1_000

  # ------------------------------------------------------------------ starting

  @doc """
  Starts an instance. See the moduledoc and `Aerotow.Instance` for the
  options, which may also come as a function that returns them (as
  `child_spec/1` passes them). A `dir` another instance has open is
  `{:error, reason}` saying so.
  """
  @spec start_link(keyword() | (-> keyword())) :: Supervisor.on_start() | {:error, String.t()}
  def start_link(opts) when is_function(opts, 0), do: start_link(opts.())

  def start_link(opts) do
    with {:ok, config} <- Options.check(opts) do
      case Aerotow.Supervisor.start_link(config) do
        {:error, {:shutdown, {:failed_to_start_child, Catalog, reason}}} ->
          {:error, catalog_failed(config.dir, reason)}

        {:error, {:shutdown, {:failed_to_start_child, Server, reason}}} ->
          {:error, reason}

        other ->
          other
      end
    end
  end

  defp catalog_failed(dir, reason) when is_binary(reason) do
    if reason =~ "locked",
      do: "#{dir} is in use: another aerotow instance has its catalog open (#{reason})",
      else: "the catalog in #{dir} could not be opened: #{reason}"
  end

  defp catalog_failed(dir, reason),
    do: "the catalog in #{dir} could not be opened: #{inspect(reason)}"

  @doc """
  A child spec, so `{Aerotow, opts}` goes in a supervision tree. The options
  are passed to `start_link/1` inside a function, so a supervisor's report
  of the child never shows a store's credentials (R4).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [fn -> opts end]},
      type: :supervisor,
      shutdown: :infinity
    }
  end

  # ------------------------------------------------------------------ stores

  @doc """
  Adds a store while running: it is made and probed (`Aerotow.Store.new/3`),
  recorded in the catalog and scanned. Answers what `stores/1` shows of it.
  """
  @spec add_store(tow(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def add_store(tow, name, url, opts \\ []) do
    with {:ok, instance} <- instance(tow),
         {:ok, spec} <- Options.store({name, url, opts}),
         :ok <- if(Server.store?(instance, name), do: {:error, :exists}, else: :ok),
         {:ok, store} <- Store.new(name, url, Keyword.put_new(opts, :clock, instance.clock)),
         :ok <- Server.attach_store(instance, store, spec) do
      _ = Server.scan(instance, name)
      {:ok, store |> Store.public() |> Map.merge(%{available: true, reason: nil})}
    end
  end

  @doc """
  Removes a store: the flights homed in it land first, then the store and
  its gliders leave the catalog. Nothing in the store itself is touched.
  """
  @spec remove_store(tow(), String.t()) :: :ok | {:error, reason()}
  def remove_store(tow, name) when is_binary(name) do
    with {:ok, instance} <- instance(tow),
         :ok <- Server.detach_store(instance, name) do
      instance.registry
      |> Registry.select([{{:_, :"$1", :"$2"}, [{:==, :"$2", name}], [:"$1"]}])
      |> Task.async_stream(&Flight.land(&1, instance.sync_timeout),
        timeout: :infinity,
        ordered: false
      )
      |> Stream.run()

      case Catalog.delete_store(instance.catalog, name) do
        {:ok, _refs} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def remove_store(_tow, name), do: {:error, "a store's name is a string, got: #{inspect(name)}"}

  @doc """
  The stores, in the order they were given, without credentials (R4): each
  `%{name, kind, url, cas, available, reason}`.
  """
  @spec stores(tow()) :: {:ok, [map()]} | {:error, reason()}
  def stores(tow) do
    with {:ok, instance} <- instance(tow), do: {:ok, Server.stores(instance)}
  end

  @doc """
  Reads the cards in a store into the catalog now (`Aerotow.Scan`), and
  waits for it. With a store's name, `{:ok, summary}` or why it failed; with
  `:all`, `{:ok, %{name => {:ok, summary} | {:error, reason}}}`.
  """
  @spec scan(tow(), :all | String.t()) :: {:ok, map()} | {:error, reason()}
  def scan(tow, store \\ :all)

  def scan(tow, :all) do
    with {:ok, instance} <- instance(tow), do: Server.scan(instance, :all)
  end

  def scan(tow, name) when is_binary(name) do
    with {:ok, instance} <- instance(tow),
         {:ok, %{^name => result}} <- Server.scan(instance, name),
         do: result
  end

  # ------------------------------------------------------------------ gliders

  @doc """
  Creates a new, empty glider, homed in `store:` (or the instance's
  `default_store`), with the card fields `description:`, `tags:`, `attrs:`,
  `links:`, `mode:` and `hot:`. It is left aloft here, and lands when idle.
  A ref that exists anywhere a store can tell (this catalog, or a card in
  any store that can be reached) is `{:error, :exists}`.

  With a `peer` store for `store:`, the peer creates it, in its own default
  store, and its card comes into this catalog homed in the peer store.
  """
  @spec create(tow(), Ref.t(), keyword()) :: {:ok, Card.t()} | {:error, reason()}
  def create(tow, ref, opts \\ []), do: new_glider(tow, ref, opts, nil)

  @doc """
  Brings an existing `.gldb` file in as a new glider, as `create/3` does
  with an empty one. The file is copied, not moved, and nothing may have it
  open.
  """
  @spec adopt(tow(), Ref.t(), Path.t(), keyword()) :: {:ok, Card.t()} | {:error, reason()}
  def adopt(tow, ref, path, opts \\ [])

  def adopt(tow, ref, path, opts) when is_binary(path),
    do: new_glider(tow, ref, opts, Path.expand(path))

  def adopt(_tow, _ref, path, _opts),
    do: {:error, "adopt takes the path of a .gldb file, got: #{inspect(path)}"}

  defp new_glider(tow, ref, opts, from) do
    with {:ok, instance} <- instance(tow),
         {:ok, ref} <- Ref.parse(ref),
         :ok <- keyword(opts),
         {store_name, card_opts} = Keyword.pop(opts, :store),
         {:ok, card} <- Card.new(ref, card_opts),
         {:ok, store} <- home_for(instance, store_name),
         :ok <- if(Server.purging?(instance, ref), do: {:error, :purging}, else: :ok),
         :ok <- nowhere(instance, ref) do
      intent = if from, do: {:adopt, card, from}, else: {:create, card}

      cond do
        store.kind != :peer ->
          with {:ok, pid} <- start(instance, store, ref, intent, false, @tries) do
            {:ok, Flight.card(pid)}
          end

        from == nil ->
          Forward.to_peer(instance, store, {:create, ref, card_opts})

        true ->
          {:error, {:runs_on_peer, store.name}}
      end
    end
  end

  defp home_for(instance, nil) do
    case instance.default_store do
      nil -> {:error, "a new glider needs store: (this aerotow has no default_store)"}
      name -> home_for(instance, name)
    end
  end

  defp home_for(instance, name), do: Server.store(instance, name)

  # A ref is new only where nothing can tell of it: not in the catalog, not
  # aloft here, and no card in any store that answers.
  defp nowhere(instance, ref) do
    cond do
      Registry.lookup(instance.registry, ref) != [] ->
        {:error, :exists}

      match?({:ok, _}, Catalog.card(instance.catalog, ref)) ->
        {:error, :exists}

      Enum.any?(Server.available_stores(instance), &match?({:ok, _}, Store.read_card(&1, ref))) ->
        {:error, :exists}

      true ->
        :ok
    end
  end

  @doc """
  Changes what somebody sets on a glider's card: `description`, `tags`,
  `attrs`, `links`, `mode`, `hot`. Only the holder of a glider's flight
  writes its card, so a hangared glider is launched for it and left aloft,
  to land when idle.
  """
  @spec update(tow(), Ref.t(), keyword() | map()) :: {:ok, Card.t()} | {:error, reason()}
  def update(tow, ref, changes) do
    with {:ok, instance} <- instance(tow) do
      case flight(instance, ref, false) do
        {:ok, pid} -> Flight.update_card(pid, changes)
        error -> forward(instance, error, {:update, ref, changes})
      end
    end
  end

  @doc """
  Reads a glider's counts and schema again from the glider itself and
  writes them on its card. A hangared glider is launched for it, as for
  `update/3`.
  """
  @spec describe(tow(), Ref.t()) :: {:ok, Card.t()} | {:error, reason()}
  def describe(tow, ref) do
    with {:ok, instance} <- instance(tow),
         {:ok, pid} <- flight(instance, ref, false) do
      Flight.describe(pid)
    end
  end

  @doc """
  A glider's card: the flight's, when it is aloft here; the peer's, asked
  now, when it is homed in a peer store; otherwise the catalog's, or on a
  miss the first store's that has one (R3).
  """
  @spec card(tow(), Ref.t()) :: {:ok, Card.t()} | {:error, reason()}
  def card(tow, ref) do
    with {:ok, instance} <- instance(tow),
         {:ok, ref} <- Ref.parse(ref) do
      case Registry.lookup(instance.registry, ref) do
        [{pid, _store}] ->
          case safe(fn -> Flight.card(pid) end) do
            %Card{} = card -> {:ok, card}
            _gone -> Router.card(instance, ref)
          end

        [] ->
          with {:ok, card} <- Router.card(instance, ref) do
            case Server.store(instance, card.store) do
              {:ok, %Store{kind: :peer} = peer} -> Forward.to_peer(instance, peer, {:card, ref})
              _ -> {:ok, card}
            end
          end
      end
    end
  end

  @doc """
  Deletes a glider.

  Without `purge: true` it is forgotten by this catalog only, after a
  flight of it here has landed; the store keeps it, and a scan brings it
  back. With `purge: true` it is deleted from its store, as
  `Aerotow.Purge` describes, and is `:not_found` everywhere afterwards.

  A glider homed in a peer store is deleted by the peer, as it would be by
  this call there, and forgotten here.
  """
  @spec delete(tow(), Ref.t(), keyword()) :: :ok | {:error, reason()}
  def delete(tow, ref, opts \\ []) do
    with {:ok, instance} <- instance(tow),
         {:ok, ref} <- Ref.parse(ref),
         :ok <- keyword(opts),
         :ok <- known_options(opts, [:purge]) do
      purge = Keyword.get(opts, :purge, false) == true

      case peer_home(instance, ref) do
        {:ok, peer} ->
          with {:ok, :ok} <- Forward.to_peer(instance, peer, {:delete, ref, [purge: purge]}),
               do: :ok

        :no ->
          if purge, do: Purge.run(instance, ref), else: forget(instance, ref)
      end
    end
  end

  # The peer store a glider is homed in, by the catalog.
  defp peer_home(instance, ref) do
    with {:ok, card} <- Catalog.card(instance.catalog, ref),
         {:ok, %Store{kind: :peer} = peer} <- Server.store(instance, card.store) do
      {:ok, peer}
    else
      _ -> :no
    end
  end

  defp forget(instance, ref) do
    with {:ok, _card} <- Catalog.card(instance.catalog, ref) do
      case Registry.lookup(instance.registry, ref) do
        [{pid, _}] -> _ = Flight.land(pid, instance.sync_timeout)
        [] -> :ok
      end

      Catalog.delete_card(instance.catalog, ref)
    end
  end

  # ------------------------------------------------------------------ find

  @doc """
  Read-only Cypher over the catalog: what statements `query/5` takes, and
  nothing else (R17). The catalog first takes in what has been written here
  since it last looked, so a glider written here is found by what it holds.
  """
  @spec find(tow(), String.t(), Glider.params()) :: {:ok, Glider.Result.t()} | {:error, reason()}
  def find(tow, cypher, params \\ %{}) do
    with {:ok, instance} <- instance(tow),
         :ok <- Statement.check_read(cypher) do
      observe_written(instance)
      Catalog.find(instance.catalog, cypher, params)
    end
  end

  @doc """
  A page of cards: `store:`, `tag:`, `label:`, `type:`, `prefix:`,
  `where:`, `limit:`, `after:`, as `Aerotow.Catalog.list/2` takes them.
  """
  @spec gliders(tow(), keyword()) ::
          {:ok, %{gliders: [Card.t()], next: Ref.t() | nil}} | {:error, reason()}
  def gliders(tow, opts \\ []) do
    with {:ok, instance} <- instance(tow) do
      observe_written(instance)
      Catalog.list(instance.catalog, opts)
    end
  end

  @doc "Cards by full text, best first. `top:` says how many (10)."
  @spec search(tow(), String.t(), keyword()) ::
          {:ok, [%{ref: Ref.t(), score: float(), card: Card.t()}]} | {:error, reason()}
  def search(tow, text, opts \\ []) do
    with {:ok, instance} <- instance(tow) do
      observe_written(instance)
      Catalog.search(instance.catalog, text, opts)
    end
  end

  @doc """
  The catalog's glider handle, for `Glider.Context` and the like. Read it;
  do not write it: the catalog's own process is its only writer.
  """
  @spec catalog(tow()) :: {:ok, Glider.db()} | {:error, reason()}
  def catalog(tow) do
    with {:ok, instance} <- instance(tow) do
      case safe(fn -> Catalog.db(instance.catalog) end) do
        {:exit, _} -> {:error, :not_running}
        db -> {:ok, db}
      end
    end
  end

  # Cards are observed when a flight lands or is described. A glider
  # written here since is described now, so what the catalog says of it is
  # what it holds.
  defp observe_written(instance) do
    for ref <- Server.take_written(instance) do
      case Registry.lookup(instance.registry, ref) do
        [{pid, _}] -> safe(fn -> Flight.describe(pid) end)
        [] -> :ok
      end
    end

    :ok
  end

  # ------------------------------------------------------------------ interact

  @doc """
  A statement that reads, on the glider wherever it is. Only statements
  that provably read are taken (`Aerotow.Statement`, R17): anything else is
  refused with a message naming `run/5`, and never reaches the glider.

  Options: `max_rows:` (10,000), `max_bytes:` (8 MiB) and `graph:` (false),
  as `Glider.query/4` takes them, so a result over the cap is an error and
  not a large term; and `timeout:` for the checkout (30 s).
  """
  @spec query(tow(), Ref.t(), String.t(), Glider.params(), keyword()) ::
          {:ok, Glider.Result.t()} | {:error, reason()}
  def query(tow, ref, cypher, params \\ %{}, opts \\ []) do
    with :ok <- keyword(opts),
         :ok <- known_options(opts, @query_options),
         :ok <- Statement.check_read(cypher) do
      bounds = [
        max_rows: Keyword.get(opts, :max_rows, 10_000),
        max_bytes: Keyword.get(opts, :max_bytes, 8 * 1024 * 1024),
        graph: Keyword.get(opts, :graph, false)
      ]

      forwarded =
        {:query, ref, cypher, params, Keyword.take(opts, [:max_rows, :max_bytes, :graph])}

      statement(tow, ref, :query, :read, opts, forwarded, fn db ->
        Glider.query(db, cypher, params, bounds)
      end)
    end
  end

  @doc """
  A statement that writes (or any statement but `BEGIN`, `COMMIT` and
  `ROLLBACK`). Answers `{:ok, touched}`. The flight is marked as written
  exactly when the statement is a write. `sync: :commit` ships before it
  answers, and answers `{:error, :lost}` if the lease ran out first (R11).
  """
  @spec run(tow(), Ref.t(), String.t(), Glider.params(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def run(tow, ref, cypher, params \\ %{}, opts \\ []) do
    with :ok <- keyword(opts),
         :ok <- known_options(opts, @run_options),
         :ok <- Statement.check_run(cypher) do
      mode = if Statement.classify(cypher) == :write, do: :write, else: :read
      forwarded = {:run, ref, cypher, params, Keyword.take(opts, [:sync])}
      statement(tow, ref, :run, mode, opts, forwarded, &Glider.run(&1, cypher, params))
    end
  end

  @doc """
  Up to #{@max_batch} writes, `[{cypher, params}]`, applied all or none
  (`Glider.write_batch/2`). Answers `{:ok, touched}`.
  """
  @spec write_batch(tow(), Ref.t(), [{String.t(), Glider.params()}], keyword()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def write_batch(tow, ref, statements, opts \\ []) do
    with :ok <- keyword(opts),
         :ok <- known_options(opts, @run_options),
         :ok <- batch(statements) do
      forwarded = {:write_batch, ref, statements, Keyword.take(opts, [:sync])}

      statement(tow, ref, :write_batch, :write, opts, forwarded, fn db ->
        Glider.write_batch(db, statements)
      end)
    end
  end

  defp batch(statements) when is_list(statements) and length(statements) <= @max_batch do
    Enum.reduce_while(statements, :ok, fn
      {cypher, _params}, :ok ->
        case Statement.check_run(cypher) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      other, :ok ->
        {:halt,
         {:error, "a batch is a list of {cypher, params}, got: #{inspect(other, limit: 5)}"}}
    end)
  end

  defp batch(statements) when is_list(statements),
    do: {:error, "a batch is at most #{@max_batch} statements"}

  defp batch(_), do: {:error, "a batch is a list of {cypher, params}"}

  @doc "`Glider.Context.retrieve/2` on the glider, with `opts` as it takes them."
  @spec context(tow(), Ref.t(), keyword()) :: {:ok, term()} | {:error, reason()}
  def context(tow, ref, opts \\ []) do
    with :ok <- keyword(opts) do
      {timeout, opts} = Keyword.pop(opts, :timeout)
      run_opts = if timeout, do: [timeout: timeout], else: []
      forwarded = {:context, ref, opts}

      statement(tow, ref, :context, :read, run_opts, forwarded, fn db ->
        Glider.Context.retrieve(db, opts)
      end)
    end
  end

  @doc "The glider's schema, as `Glider.schema/1`."
  @spec schema(tow(), Ref.t()) :: {:ok, map()} | {:error, reason()}
  def schema(tow, ref),
    do: statement(tow, ref, :schema, :read, [], {:schema, ref}, &Glider.schema/1)

  @doc "The glider's stats, as `Glider.stats/1`."
  @spec stats(tow(), Ref.t()) :: {:ok, map()} | {:error, reason()}
  def stats(tow, ref),
    do: statement(tow, ref, :stats, :read, [], {:stats, ref}, &Glider.stats/1)

  @doc """
  `fun.(db)` with the glider's open handle, in the calling process, here
  only: for transactions (`Glider.transaction/2`), `Glider.Query`,
  ash_glider. Answers `{:ok, fun_result}`. The flight is marked as written,
  whatever `fun` does. A glider aloft elsewhere is `{:error,
  {:aloft_elsewhere, holder}}`. Options: `timeout:`, `sync: :commit`.
  """
  @spec checkout(tow(), Ref.t(), (Glider.db() -> result), keyword()) ::
          {:ok, result} | {:error, reason()}
        when result: term()
  def checkout(tow, ref, fun, opts \\ []) when is_function(fun, 1) do
    with :ok <- keyword(opts),
         :ok <- known_options(opts, @run_options) do
      statement(tow, ref, :checkout, :write, opts, nil, &{:ok, fun.(&1)})
    end
  end

  # Routes, launches when it has to, and runs `fun` in this process with the
  # handle lent. `fun` answers {:ok, _} or {:error, _}, which is the answer.
  # A glider homed in a peer, or aloft elsewhere, gets `forwarded` sent to
  # the instance that answers for it (`Aerotow.Forward`); with `forwarded`
  # nil (a checkout) it is refused instead.
  defp statement(tow, ref, op, mode, opts, forwarded, fun) do
    with {:ok, instance} <- instance(tow),
         {:ok, ref} <- Ref.parse(ref) do
      # Aloft here, the statement goes straight to the flight, which holds
      # it while it is still launching; only a launch waits for the flight.
      placed =
        case Router.locate(instance, ref) do
          {:ok, {:here, pid}} -> {:ok, pid}
          {:ok, {:peer, store}} -> {:peer, store}
          {:ok, {:elsewhere, holder}} -> {:error, {:aloft_elsewhere, holder}}
          routed -> fly(instance, ref, routed, false, @tries)
        end

      case placed do
        {:ok, pid} ->
          span(%{ref: ref, op: op, where: :here}, fn ->
            lend(instance, ref, pid, mode, opts, fun, @tries)
          end)

        {:error, {:aloft_elsewhere, holder}} = error ->
          span(%{ref: ref, op: op, where: :elsewhere}, fn ->
            if forwarded, do: Forward.to_holder(instance, holder, forwarded), else: error
          end)

        {:peer, store} ->
          span(%{ref: ref, op: op, where: :peer}, fn ->
            if forwarded,
              do: Forward.to_peer(instance, store, forwarded),
              else: {:error, {:runs_on_peer, store.name}}
          end)

        error ->
          error
      end
    end
  end

  # A call that runs where the glider is open, sent there: to the peer it
  # is homed in, or to the holder of its flight.
  defp forward(instance, {:error, {:runs_on_peer, name}} = error, request) do
    case Server.store(instance, name) do
      {:ok, %Store{kind: :peer} = peer} -> Forward.to_peer(instance, peer, request)
      _ -> error
    end
  end

  defp forward(instance, {:error, {:aloft_elsewhere, holder}}, request),
    do: Forward.to_holder(instance, holder, request)

  defp forward(_instance, error, _request), do: error

  defp lend(instance, ref, pid, mode, opts, fun, tries) do
    run_opts = Keyword.take(opts, [:timeout, :sync])

    case Flight.run(pid, mode, fun, run_opts) do
      {:ok, {:ok, _} = ok} ->
        if mode == :write, do: Server.written(instance, ref)
        ok

      {:ok, {:error, _} = error} ->
        # A statement glider refused may still have written before it did.
        if mode == :write, do: Server.written(instance, ref)
        error

      {:ok, other} ->
        {:error, {:unexpected, other}}

      {:error, why} when why in [:landing, :noproc] and tries > 1 ->
        gone(pid, instance.launch_timeout)

        with {:ok, pid} <- flight(instance, ref, false),
             do: lend(instance, ref, pid, mode, opts, fun, tries - 1)

      {:error, _} = error ->
        error
    end
  end

  defp span(meta, fun) do
    :telemetry.span([:aerotow, :statement], meta, fn ->
      result = fun.()
      {result, Map.put(meta, :result, if(match?({:error, _}, result), do: :error, else: :ok))}
    end)
  end

  # ------------------------------------------------------------------ flights

  @doc "Opens a glider here now. `pin: true` keeps it aloft when it is idle."
  @spec launch(tow(), Ref.t(), keyword()) :: :ok | {:error, reason()}
  def launch(tow, ref, opts \\ []) do
    with {:ok, instance} <- instance(tow),
         :ok <- keyword(opts),
         :ok <- known_options(opts, [:pin]),
         {:ok, pin} <- flag(Keyword.get(opts, :pin, false), :pin),
         {:ok, pid} <- flight(instance, ref, pin) do
      if pin, do: Flight.pin(pid, true)
      :ok
    end
  end

  @doc "Ships what a glider aloft here has not shipped, and closes it."
  @spec land(tow(), Ref.t()) :: :ok | {:error, reason()}
  def land(tow, ref) do
    with {:ok, instance} <- instance(tow),
         {:ok, pid} <- here(instance, ref) do
      case Flight.land(pid) do
        {:error, :noproc} -> :ok
        other -> other
      end
    end
  end

  @doc "Ships now what a glider aloft here has not shipped, and waits for it."
  @spec sync(tow(), Ref.t()) :: {:ok, map()} | {:error, reason()}
  def sync(tow, ref) do
    with {:ok, instance} <- instance(tow),
         {:ok, pid} <- here(instance, ref) do
      Flight.sync(pid)
    end
  end

  @doc "What is aloft here: each flight's `Aerotow.Flight.info/1`."
  @spec aloft(tow()) :: {:ok, [map()]} | {:error, reason()}
  def aloft(tow) do
    with {:ok, instance} <- instance(tow) do
      infos =
        instance.registry
        |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
        |> Enum.flat_map(fn pid ->
          case safe(fn -> Flight.info(pid) end) do
            %{} = info -> [info]
            _gone -> []
          end
        end)
        |> Enum.sort_by(& &1.ref)

      {:ok, infos}
    end
  end

  @doc """
  Where a glider is: `:here`, `{:elsewhere, holder}`, `{:peer, store}` or
  `:hangared`.
  """
  @spec where(tow(), Ref.t()) :: {:ok, place()} | {:error, reason()}
  def where(tow, ref) do
    with {:ok, instance} <- instance(tow) do
      case Router.locate(instance, ref) do
        {:ok, {:here, _pid}} -> {:ok, :here}
        {:ok, {:elsewhere, holder}} -> {:ok, {:elsewhere, holder}}
        {:ok, {:peer, store}} -> {:ok, {:peer, store.name}}
        {:ok, {:launch, _store}} -> {:ok, :hangared}
        error -> error
      end
    end
  end

  defp here(instance, ref) do
    with {:ok, ref} <- Ref.parse(ref) do
      case Registry.lookup(instance.registry, ref) do
        [{pid, _}] -> {:ok, pid}
        [] -> {:error, :not_aloft}
      end
    end
  end

  # A flight of `ref` here that is up: the one there is, or one launched now.
  defp flight(instance, ref, pin, tries \\ @tries),
    do: fly(instance, ref, Router.route(instance, ref), pin, tries)

  defp fly(instance, ref, routed, pin, tries) do
    case routed do
      {:ok, {:here, pid}} ->
        case Flight.await(pid, instance.launch_timeout) do
          :ok ->
            {:ok, pid}

          {:error, why} when why in [:landing, :noproc, :lost] and tries > 1 ->
            gone(pid, instance.launch_timeout)
            flight(instance, ref, pin, tries - 1)

          {:error, _} = error ->
            error
        end

      {:ok, {:launch, store}} ->
        start(instance, store, ref, :launch, pin, tries)

      error ->
        error
    end
  end

  # Starts a flight with room made for it. A copy left where the working
  # copy goes is dealt with (`Aerotow.Copies.found/4`) and the launch tried
  # again; so is a flight of the same ref that was on its way down.
  defp start(instance, store, ref, intent, pin, tries) do
    with {:ok, token} <- Server.room(instance, ref) do
      result =
        Flight.start(instance: instance, store: store, ref: ref, intent: intent, pin: pin)

      Server.done(instance, token)

      case result do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:launch, {:copy_exists, path}}} when tries > 1 ->
          with {:ok, intent} <- left_behind(instance, store, ref, path, intent),
               do: start(instance, store, ref, intent, pin, tries - 1)

        {:error, :landing} when tries > 1 and intent == :launch ->
          case Registry.lookup(instance.registry, ref) do
            [{pid, _}] -> gone(pid, instance.launch_timeout)
            [] -> :ok
          end

          flight(instance, ref, pin, tries - 1)

        {:error, {:aloft, lease}} ->
          {:error, {:aloft_elsewhere, Router.holder(lease)}}

        {:error, :not_found} ->
          forget_if_gone(instance, store, ref)
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    end
  end

  defp left_behind(instance, store, ref, path, :launch),
    do: Copies.found(instance, store, ref, path)

  defp left_behind(instance, _store, _ref, path, intent) do
    with :ok <- Copies.set_aside(instance, path), do: {:ok, intent}
  end

  # A glider that launches as not found, and whose store has no card for it
  # either, was purged by somebody else: the catalog forgets it.
  defp forget_if_gone(instance, store, ref) do
    if Store.read_card(store, ref) == {:error, :not_found},
      do: Catalog.delete_card(instance.catalog, ref)
  end

  defp gone(pid, timeout) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      timeout -> Process.demonitor(monitor, [:flush])
    end
  end

  # ------------------------------------------------------------------ helpers

  defp instance(tow) when is_atom(tow), do: Instance.fetch(tow)
  defp instance(_tow), do: {:error, :not_running}

  defp keyword(opts) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: :ok,
      else: {:error, "options are a keyword list"}
  end

  defp known_options(opts, known) do
    case Enum.reject(Keyword.keys(opts), &(&1 in known)) do
      [] -> :ok
      [key | _] -> {:error, "#{inspect(key)} is not an option here (#{inspect(known)})"}
    end
  end

  defp flag(value, _name) when is_boolean(value), do: {:ok, value}
  defp flag(other, name), do: {:error, "#{name} is true or false, got: #{inspect(other)}"}

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:exit, reason}
  end
end
