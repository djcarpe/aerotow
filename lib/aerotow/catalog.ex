defmodule Aerotow.Catalog do
  @moduledoc """
  This instance's graph of metadata: a glider file with a node for every
  glider's card and every store. Finding a glider is a query over it.

      (:Store   {name, kind, url, cas, scanned_at})
      (:Glider  {ref, namespace, name, description, tags, mode, hot,
                 nodes, edges, bytes, schema, text,
                 flight, generation, position, aloft, known,
                 created_at, updated_at, described_at, attr_names, ...attrs})
      (:Label {name})   (:EdgeType {name})   (:Tag {name})

      (:Glider)-[:HOMED_IN {version}]->(:Store)    exactly one, for a known glider
      (:Glider)-[:ALSO_IN {version}]->(:Store)     the same ref seen in a second store
      (:Glider)-[:HAS_LABEL {count}]->(:Label)
      (:Glider)-[:HAS_TYPE  {count}]->(:EdgeType)
      (:Glider)-[:TAGGED]->(:Tag)
      (:Glider)-[:LINKS_TO]->(:Glider)            the target may be a stub: {ref, known: false}

  It is a map, not the truth. Everything in it was read from the stores'
  cards or written by this instance, so the file can be deleted and rebuilt
  by putting the same stores and cards again (R2).

  ## One writer

  This process owns the file and makes every write. Reads (`card/2`,
  `find/3`, `list/2`, `search/3`, `count/1`, `stores/1`, `refs_in/2`) run in
  the calling process on the handle and never wait on this one. Glider
  serialises calls on one handle, and a write is a write slice, which
  commits whole or not at all, so a reader sees a card as it was before an
  upsert or after it, never half of it.

  The handle is in an ETS table this process owns, found through
  `:persistent_term` by the catalog's pid or name. A catalog that is killed
  takes the table, the handle and the file's lock with it, so it can be
  started again on the same file straight away.

  ## How a card is kept

  A known glider's node holds its whole card, so a card is read from one
  node: every field under its own name; labels, types and indexes as flat
  lists of name and count (`["CodeEntity", 30000, "Ctx", 82500]`); its
  links; its attrs under their own names, with `attr_names` saying which
  properties are attrs. The edges say the same things for queries, and are
  written in the same slice.

  Labels, types and tags are shared nodes. A stub stands for a link target
  that has no card; when the card arrives the stub becomes it. A shared
  node or a stub that nothing points at any more is deleted by the write
  that let go of it, so the catalog holds what the cards say and nothing
  that was in a card before.

  A write slice is what glider allows: at most 1,000 statements, and a
  budget of bytes (32 for each byte of statement text, plus the
  parameters). A card too large for one slice is built as a `:Draft` node
  over several slices, which no query of `:Glider` sees, and swapped in by
  one last slice that moves the links into the old node across and deletes
  it.

  `version` on `HOMED_IN` and `ALSO_IN` is what a store's listing said the
  card's version was when a scan took it, so the next scan reads only the
  cards that changed (`refs_in/2`).
  """

  use GenServer

  alias Aerotow.{Card, Ref}

  @typedoc "The catalog's pid or registered name."
  @type cat :: GenServer.server()

  @typedoc "A store as the catalog records it: no credentials, ever."
  @type store :: %{
          name: String.t(),
          kind: Aerotow.Store.kind(),
          url: String.t(),
          cas: boolean() | nil,
          scanned_at: integer() | nil
        }

  @typedoc "What `replace_store_cards/4` did."
  @type scan_result :: %{
          added: non_neg_integer(),
          updated: non_neg_integer(),
          removed: non_neg_integer(),
          conflicts: [Ref.t()]
        }

  # A statement and its `$name` parameters.
  @typep statement :: {String.t(), %{String.t() => term()}}

  # The property indexes every lookup is anchored on.
  @indexes [
    {"Glider", "ref"},
    {"Store", "name"},
    {"Label", "name"},
    {"EdgeType", "name"},
    {"Tag", "name"}
  ]

  # What the context extension's full-text index covers.
  @text_labels ["Glider"]
  @text_keys ["ref", "description", "text"]

  @kinds %{"file" => :file, "dir" => :dir, "s3" => :s3, "peer" => :peer}

  # The properties a card is kept in, besides `ref` and its attrs.
  @fields ~w(namespace name description tags links mode hot nodes edges bytes labels types
             indexes extensions schema text flight generation position aloft known
             created_at updated_at described_at attr_names)

  # A card's names that are shared nodes.
  @shared [{:labels, "Label"}, {:types, "EdgeType"}, {:tags, "Tag"}]

  # Each kind of edge from a glider to what its card names:
  # {field, label, key, relationship, counted?}
  @edges [
    {:labels, "Label", "name", "HAS_LABEL", true},
    {:types, "EdgeType", "name", "HAS_TYPE", true},
    {:tags, "Tag", "name", "TAGGED", false},
    {:links, "Glider", "ref", "LINKS_TO", false}
  ]

  # The only names that go into a statement as identifiers: the constants
  # above, and attr names, which `Aerotow.Card` has already held to this.
  @ident ~r/\A[a-z][a-z0-9_]{0,62}\z/

  @int_max 9_223_372_036_854_775_807
  @int_min -9_223_372_036_854_775_808
  @max_name 1_024
  @max_counts 10_000

  # Patterns one statement matches or creates. It keeps a statement small
  # and the matcher's recursion shallow: glider's matcher recurses once for
  # each pattern of a MATCH, and the VM dies between 150 and 200 of them.
  @per_statement 25
  @max_statements 1_000

  # A card has at most 64 attrs, so a `where:` naming more matches nothing.
  # The bound also keeps its chain of ANDs short.
  @max_where 64

  # glider_ex opens a file with a work_mem of 32 MiB, or half the process's
  # query workspace when that is less, and never under 64 KiB. A write slice
  # may use an eighth of it.
  @work_mem 32 * 1024 * 1024
  @min_query_mem 64 * 1024

  @limit 50
  @max_limit 500
  @top 10
  @max_top 500
  @max_text 4_096
  @max_ask 4_096

  # An answer to one query is at most 10,000 rows and 8 MiB. So whatever
  # reads every glider of a store does it a page of refs at a time, and a
  # card is never larger than a store hands back (`Aerotow.Card.decode/1`'s
  # limit), so one card always reads whole.
  @page 5_000
  @max_card 1_048_576

  # What a catalog does when it starts after one that died part way through
  # a draft: nothing a write left half done survives, and nothing that
  # nothing points at.
  @sweep [
    "MATCH (n:Draft) DELETE n",
    "MATCH (x:Label) WHERE degree(x) = 0 DELETE x",
    "MATCH (x:EdgeType) WHERE degree(x) = 0 DELETE x",
    "MATCH (x:Tag) WHERE degree(x) = 0 DELETE x",
    "MATCH (g:Glider {known: false}) WHERE indegree(g) = 0 DELETE g"
  ]

  # ------------------------------------------------------------------ starting

  @doc """
  Starts the catalog, the only writer of its file. Options:

    * `:path` - the catalog's `.gldb` file. It and its directory are
      created when absent. Required.
    * `:name` - a name to register the process under. Readers can then
      pass the name instead of the pid.
    * `:slice_bytes` - the most one write slice may hold, in glider's
      accounting. Defaults to what glider allows; a smaller one is for tests
      of what happens to a card too large for one slice.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The catalog's glider handle, for reads. Taken from an ETS table without a
  call to the catalog, so it is there while the catalog is busy. Do not
  write through it: every write goes through the catalog. Exits with
  `:noproc` when no catalog of that pid or name is running.
  """
  @spec db(cat()) :: Glider.db()
  def db(cat) do
    with table when table != nil <- :persistent_term.get({__MODULE__, cat}, nil),
         [{:db, db}] <- lookup(table) do
      db
    else
      _ -> exit({:noproc, {__MODULE__, :db, [cat]}})
    end
  end

  defp lookup(table) do
    :ets.lookup(table, :db)
  rescue
    ArgumentError -> []
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, path} <- path_option(opts),
         {:ok, budget} <- budget(Keyword.get(opts, :slice_bytes)),
         :ok <- make_dir(Path.dirname(path)),
         {:ok, db} <- Glider.open(path) do
      case prepare(db) do
        :ok ->
          table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
          true = :ets.insert(table, {:db, db})
          keys = for who <- [self(), Keyword.get(opts, :name)], who != nil, do: {__MODULE__, who}
          Enum.each(keys, &:persistent_term.put(&1, table))
          {:ok, %{db: db, keys: keys, budget: budget}}

        {:error, reason} ->
          Glider.close(db)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.keys, &:persistent_term.erase/1)
    Glider.close(state.db)
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp path_option(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      other -> {:error, "a catalog needs path: its .gldb file, got: #{inspect(other)}"}
    end
  end

  defp make_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot make #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp budget(asked) do
    %{work_limit_bytes: work} = Glider.memory_budget()
    allowed = div(max(min(@work_mem, div(work, 2)), @min_query_mem), 8)

    case asked do
      nil -> {:ok, div(allowed * 7, 8)}
      n when is_integer(n) and n > 0 -> {:ok, min(n, allowed)}
      other -> {:error, "slice_bytes is a number of bytes, got: #{inspect(other)}"}
    end
  end

  # The indexes, the context extension and its full-text index, each made
  # only if the file does not have it yet: reopening keeps what is there.
  defp prepare(db) do
    with {:ok, schema} <- Glider.schema(db),
         :ok <- make_indexes(db, MapSet.new(schema.indexes, & &1.name)),
         :ok <- Glider.Context.install(db),
         :ok <- make_text_index(db) do
      tidy(db)
    end
  end

  defp make_indexes(db, existing) do
    Enum.reduce_while(@indexes, :ok, fn {label, key}, :ok ->
      if MapSet.member?(existing, ":#{label}(#{key})") do
        {:cont, :ok}
      else
        case Glider.run(db, "INDEX ON :#{label}(#{key})") do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  # The extension answers a search from its index when it has one and says
  # so; without one it scans, and says that instead.
  defp make_text_index(db) do
    case Glider.query(db, "CALL context.search(query: $q, label: $label, top: 1)",
           q: "catalog",
           label: "Glider"
         ) do
      {:ok, %{message: message}} when is_binary(message) ->
        if message =~ "text index", do: :ok, else: build_text_index(db)

      {:ok, _} ->
        build_text_index(db)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_text_index(db) do
    case Glider.Context.index(db, labels: @text_labels, keys: @text_keys) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp tidy(db) do
    case Glider.query(db, "MATCH (n:Draft) RETURN id(n) LIMIT 1") do
      {:ok, %{rows: []}} -> :ok
      {:ok, _} -> sweep(db)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sweep(db) do
    case Glider.write_batch(db, Enum.map(@sweep, &{&1, %{}})) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------ stores

  @doc """
  Records a store: the map `Aerotow.Store.public/1` gives, plus
  `scanned_at` when it is known. Only `name`, `kind`, `url`, `cas` and
  `scanned_at` are read; any `user:password@` in the url is removed, so
  nothing secret reaches the catalog (R4). A store already recorded is
  updated, keeping its `scanned_at` unless the map gives one.
  """
  @spec put_store(cat(), map()) :: :ok | {:error, String.t()}
  def put_store(cat, store) do
    with {:ok, store} <- check_store(store) do
      GenServer.call(cat, {:put_store, store}, :infinity)
    end
  end

  @doc "The stores, by name."
  @spec stores(cat()) :: [store()]
  def stores(cat) do
    cat
    |> db()
    |> rows!("MATCH (s:Store) RETURN s.name, s ORDER BY s.name", %{})
    |> Enum.map(fn [_, %Glider.Node{props: p}] ->
      %{
        name: p["name"],
        kind: Map.get(@kinds, p["kind"]),
        url: p["url"],
        cas: p["cas"],
        scanned_at: p["scanned_at"]
      }
    end)
  end

  @doc """
  Forgets a store, and every glider homed in it with its edges. Returns
  their refs. A glider homed there and also seen in another store is gone
  too, until that store is scanned again: nothing is promoted. One that
  other gliders link to stays as a stub.
  """
  @spec delete_store(cat(), String.t()) :: {:ok, [Ref.t()]} | {:error, String.t()}
  def delete_store(cat, name) when is_binary(name),
    do: GenServer.call(cat, {:delete_store, name}, :infinity)

  @doc "Records when a store was last scanned, in unix seconds."
  @spec touch_store(cat(), String.t(), integer()) :: :ok | {:error, String.t()}
  def touch_store(cat, name, scanned_at)
      when is_binary(name) and is_integer(scanned_at) and scanned_at >= @int_min and
             scanned_at <= @int_max,
      do: GenServer.call(cat, {:touch_store, name, scanned_at}, :infinity)

  # ------------------------------------------------------------------ cards

  @doc """
  Puts a card: adds the glider, or makes the one in the catalog say what
  the card says, leaving nothing of what it said before. `card.store` names
  its home, a store the catalog has; a glider homed elsewhere moves there.
  `aloft` is kept as given. Putting the card the catalog already has writes
  nothing.

  The card is checked as one read from a store is, and for what glider can
  hold: integers in 64 bits and text that is UTF-8.
  """
  @spec put_card(cat(), Card.t()) :: :ok | {:error, String.t()}
  def put_card(cat, card) do
    with {:ok, card} <- check_card(card) do
      GenServer.call(cat, {:put, [card]}, :infinity)
    end
  end

  @doc """
  Puts many cards, as `put_card/2` does each, as many to a write slice as
  fit. Every card is checked before anything is written; a card for a ref
  given twice is the later one. A write that fails part way leaves the
  slices before it written, and the error says what failed.
  """
  @spec put_cards(cat(), [Card.t()]) :: :ok | {:error, String.t()}
  def put_cards(cat, cards) when is_list(cards) do
    checked =
      cards
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {card, i}, {:ok, acc} ->
        case check_card(card) do
          {:ok, card} -> {:cont, {:ok, [card | acc]}}
          {:error, reason} -> {:halt, {:error, "card #{i}: #{reason}"}}
        end
      end)

    with {:ok, reversed} <- checked do
      cards = reversed |> Enum.uniq_by(& &1.ref) |> Enum.reverse()
      GenServer.call(cat, {:put, cards}, :infinity)
    end
  end

  @doc "A known glider's card, with `store` its home and `aloft` as recorded. A stub has none."
  @spec card(cat(), term()) :: {:ok, Card.t()} | {:error, :not_found}
  def card(cat, ref) do
    case Ref.parse(ref) do
      {:ok, ref} -> read_card(db(cat), ref)
      {:error, _} -> {:error, :not_found}
    end
  end

  defp read_card(db, ref) do
    case rows!(
           db,
           "MATCH (g:Glider {ref: $ref, known: true})-[:HOMED_IN]->(s:Store) RETURN g, s.name",
           %{"ref" => ref}
         ) do
      [[node, store] | _] -> {:ok, card_from(node, store)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Drops a glider's card. If other gliders link to it, it stays as a stub
  and their links point at that; otherwise it is gone. A ref the catalog
  has no card for is left as it is.
  """
  @spec delete_card(cat(), term()) :: :ok | {:error, String.t()}
  def delete_card(cat, ref) do
    case Ref.parse(ref) do
      {:ok, ref} -> GenServer.call(cat, {:delete, ref}, :infinity)
      {:error, _} -> :ok
    end
  end

  @doc "Records whether a known glider is aloft here."
  @spec set_aloft(cat(), term(), boolean()) :: :ok | {:error, :not_found | String.t()}
  def set_aloft(cat, ref, aloft) when is_boolean(aloft) do
    case Ref.parse(ref) do
      {:ok, ref} -> GenServer.call(cat, {:aloft, ref, aloft}, :infinity)
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Records that a known glider's ref was also seen in a second store
  (`ALSO_IN`). Its home stays where it is. Nothing happens if that store
  is its home, or is already recorded.
  """
  @spec also_in(cat(), term(), String.t()) :: :ok | {:error, :not_found | String.t()}
  def also_in(cat, ref, store) when is_binary(store) do
    case Ref.parse(ref) do
      {:ok, ref} -> GenServer.call(cat, {:also_in, ref, store}, :infinity)
      {:error, _} -> {:error, :not_found}
    end
  end

  # ------------------------------------------------------------------ scans

  @doc """
  What the catalog has for one store, for a scan of it: the gliders homed
  there and the refs also seen there, with the version the store's listing
  gave when a scan last took each card (`nil` when no scan has).
  """
  @spec refs_in(cat(), String.t()) :: [%{ref: Ref.t(), version: String.t() | nil}]
  def refs_in(cat, store) when is_binary(store) do
    db = db(cat)

    refs =
      for rel <- ["HOMED_IN", "ALSO_IN"],
          [ref, version] <-
            paged(
              db,
              "MATCH (g:Glider {known: true})-[e:#{rel}]->(:Store {name: $store}) WHERE g.ref > $after RETURN g.ref, e.version ORDER BY g.ref LIMIT $page",
              %{"store" => store}
            ) do
        %{ref: ref, version: version}
      end

    Enum.sort_by(refs, & &1.ref)
  end

  @doc """
  Makes the catalog's view of one store what a scan of it found.

  `cards` are the cards read from the store; their `store` becomes this
  one and `aloft` false. `versions` is what the store's listing said each
  card's version was, kept for `refs_in/2`. New refs are added and changed
  cards updated. A glider homed in the store whose ref is in neither
  `cards` nor `versions` is removed: a ref in `versions` alone is one the
  scan did not read again, and is left as it is. So is a glider aloft here,
  whatever the scan found. A card whose ref is homed in another store is
  not taken: it is recorded as `ALSO_IN` this store and returned in
  `conflicts`.

  A card that is not a card glider can hold is not taken, and its glider
  is left as it is, as a card the store could not read would be.
  """
  @spec replace_store_cards(cat(), String.t(), [Card.t()], %{optional(Ref.t()) => String.t()}) ::
          {:ok, scan_result()} | {:error, String.t()}
  def replace_store_cards(cat, store, cards, versions \\ %{})
      when is_binary(store) and is_list(cards) do
    with :ok <- check_versions(versions) do
      {taken, kept} = scanned(cards, store)
      GenServer.call(cat, {:replace, store, taken, versions, kept}, :infinity)
    end
  end

  # The cards a scan found that can be taken, and the refs of those that
  # cannot, whose gliders are left as they are.
  defp scanned(cards, store) do
    {taken, kept} =
      Enum.reduce(cards, {[], []}, fn
        %Card{} = card, {taken, kept} ->
          case check_card(%{card | store: store, aloft: false}) do
            {:ok, card} -> {[card | taken], kept}
            {:error, _} -> {taken, if(Ref.valid?(card.ref), do: [card.ref | kept], else: kept)}
          end

        _other, acc ->
          acc
      end)

    {taken |> Enum.uniq_by(& &1.ref) |> Enum.reverse(), kept}
  end

  defp check_versions(versions) when is_map(versions) do
    if Enum.all?(versions, fn {k, v} -> is_binary(k) and (is_nil(v) or short_text?(v)) end),
      do: :ok,
      else: {:error, "versions is a map of refs to version strings"}
  end

  defp check_versions(_), do: {:error, "versions is a map of refs to version strings"}

  # ------------------------------------------------------------------ finding

  @doc """
  Runs a statement over the catalog, as given, in the calling process.
  Values go as `$name` parameters.

  Whether it only reads is for the caller to check: `Aerotow.find/3` does,
  with `Aerotow.Statement`. A statement that writes would go around the one
  writer, and a raw `BEGIN` would leave the handle in a transaction that
  the catalog's own writes then refuse to join.
  """
  @spec find(cat(), String.t(), Glider.params()) ::
          {:ok, Glider.Result.t()} | {:error, String.t()}
  def find(cat, cypher, params \\ %{})

  def find(cat, cypher, params) when is_binary(cypher) do
    if params?(params),
      do: Glider.query(db(cat), cypher, params),
      else: {:error, "parameters are a map or a keyword list of names to values"}
  end

  def find(_cat, cypher, _params),
    do: {:error, "a statement is a string, got: #{inspect(cypher, limit: 5)}"}

  defp params?(params) when is_map(params),
    do: Enum.all?(Map.keys(params), &(is_atom(&1) or is_binary(&1)))

  defp params?(params) when is_list(params), do: Keyword.keyword?(params)
  defp params?(_), do: false

  @doc """
  A page of known gliders' cards, in ref order. Options, all of which must
  hold:

    * `:store` - homed in this store
    * `:tag`, `:label`, `:type` - with this tag, label or relationship type
    * `:prefix` - a ref prefix on a segment boundary, as `Aerotow.Ref.under?/2`
    * `:where` - a map of attr names to values, each equal
    * `:limit` - how many to a page: 50 unless given, at most 500
    * `:after` - the `next` of the page before

  `next` is the ref to pass as `:after` for the page that follows, or `nil`
  on the last page. A page starts after a ref, not at a count, so gliders
  added while somebody pages through shift nothing.

  The page's refs are found first and each card is then read on its own,
  so a page of large cards is never more than one answer holds. A card
  deleted between the two is left out of the page.
  """
  @spec list(cat(), keyword()) ::
          {:ok, %{gliders: [Card.t()], next: Ref.t() | nil}} | {:error, String.t()}
  def list(cat, opts \\ []) do
    db = db(cat)

    with {:ok, cypher, params, limit} <- list_query(opts),
         {:ok, %{rows: rows}} <- Glider.query(db, cypher, params) do
      {refs, more} = rows |> Enum.map(&hd/1) |> Enum.split(limit)

      cards =
        Enum.flat_map(refs, fn ref ->
          case read_card(db, ref) do
            {:ok, card} -> [card]
            {:error, :not_found} -> []
          end
        end)

      {:ok, %{gliders: cards, next: if(more != [], do: List.last(refs))}}
    end
  end

  @doc """
  Known gliders' cards by full text, best match first: a word of a
  glider's ref or description, or a label, relationship type or tag it
  holds. Options: `:top`, how many (10 unless given, at most 500).
  """
  @spec search(cat(), String.t(), keyword()) ::
          {:ok, [%{ref: Ref.t(), score: float(), card: Card.t()}]} | {:error, String.t()}
  def search(cat, text, opts \\ [])

  def search(cat, text, opts) when is_binary(text) do
    with :ok <- known_options(opts, [:top]),
         {:ok, top} <- top_option(Keyword.get(opts, :top, @top)) do
      cond do
        not String.valid?(text) or byte_size(text) > @max_text ->
          {:error, "search text is UTF-8 of at most #{@max_text} bytes"}

        # The extension finds nothing in text with no word in it.
        not String.match?(text, ~r/[[:alnum:]]/u) ->
          {:ok, []}

        true ->
          hits(db(cat), text, top, top * 2 + 8)
      end
    end
  end

  def search(_cat, text, _opts), do: {:error, "search text is a string, got: #{inspect(text)}"}

  # Stubs are in the index too, by their ref, and are left out here: so ask
  # for more than wanted, and for more again while stubs crowd the answer.
  defp hits(db, text, top, ask) do
    with {:ok, found} <- Glider.Context.search(db, text, label: "Glider", top: ask) do
      known = Enum.flat_map(found, &known_hit(db, &1))

      if length(known) >= top or length(found) < ask or ask >= @max_ask,
        do: {:ok, Enum.take(known, top)},
        else: hits(db, text, top, ask * 4)
    end
  end

  defp known_hit(db, %{id: id, score: score}) do
    case Glider.query(
           db,
           "MATCH (g:Glider {known: true})-[:HOMED_IN]->(s:Store) WHERE id(g) = $id RETURN g, s.name",
           id: id
         ) do
      {:ok, %{rows: [[node, store] | _]}} ->
        card = card_from(node, store)
        [%{ref: card.ref, score: score, card: card}]

      _ ->
        []
    end
  end

  @doc "How many gliders the catalog knows. Stubs are not gliders."
  @spec count(cat()) :: non_neg_integer()
  def count(cat) do
    case rows!(db(cat), "MATCH (g:Glider {known: true}) RETURN count(g)", %{}) do
      [[n]] -> n
      [] -> 0
    end
  end

  # ------------------------------------------------------------------ the process

  @impl true
  def handle_call(request, _from, state) do
    {:reply, write(request, state), state}
  rescue
    e in Glider.Error -> {:reply, {:error, e.message}, state}
  end

  defp write({:put_store, store}, state) do
    found = rows!(state.db, "MATCH (s:Store {name: $name}) RETURN id(s)", %{"name" => store.name})

    p = %{
      "name" => store.name,
      "kind" => store.kind,
      "url" => store.url,
      "cas" => store.cas,
      "scanned_at" => store.scanned_at
    }

    statement =
      if found == [],
        do:
          "CREATE (:Store {name: $name, kind: $kind, url: $url, cas: $cas, scanned_at: $scanned_at})",
        else:
          "MATCH (s:Store {name: $name}) SET s.kind = $kind, s.url = $url, s.cas = $cas, s.scanned_at = coalesce($scanned_at, s.scanned_at)"

    run(state, [[{statement, p}]])
  end

  defp write({:touch_store, name, at}, state) do
    run(state, [
      [{"MATCH (s:Store {name: $name}) SET s.scanned_at = $at", %{"name" => name, "at" => at}}]
    ])
  end

  defp write({:delete_store, name}, state) do
    refs =
      for [ref] <-
            paged(
              state.db,
              "MATCH (g:Glider {known: true})-[:HOMED_IN]->(:Store {name: $name}) WHERE g.ref > $after RETURN g.ref ORDER BY g.ref LIMIT $page",
              %{"name" => name}
            ),
          do: ref

    {units, gc} = removals(known_nodes(state.db, refs))
    store = [{"MATCH (s:Store {name: $name}) DELETE s", %{"name" => name}}]

    with :ok <- swept(state, run(state, units ++ [store] ++ gc_steps(gc))) do
      {:ok, refs}
    end
  end

  defp write({:put, cards}, state) do
    stores = cards |> Enum.map(& &1.store) |> Enum.uniq()

    with :ok <- stores_exist(state.db, stores),
         {:ok, _tally} <- swept(state, put_all(state, Enum.map(cards, &{&1, :put}))) do
      :ok
    end
  end

  defp write({:delete, ref}, state) do
    case known_nodes(state.db, [ref]) do
      [] ->
        :ok

      nodes ->
        {units, gc} = removals(nodes)
        swept(state, run(state, units ++ gc_steps(gc)))
    end
  end

  defp write({:aloft, ref, aloft}, state) do
    case Glider.query(state.db, "MATCH (g:Glider {ref: $ref, known: true}) SET g.aloft = $aloft",
           ref: ref,
           aloft: aloft
         ) do
      {:ok, %{touched: 0}} -> {:error, :not_found}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write({:also_in, ref, store}, state) do
    with :ok <- stores_exist(state.db, [store]),
         {{:known, _node, homes}, _} <- holding(state.db, ref, %{}) do
      if homes.home == store or Map.has_key?(homes.also, store),
        do: :ok,
        else: run(state, conflict(ref, store, nil, homes).steps)
    else
      _ -> {:error, :not_found}
    end
  end

  defp write({:replace, store, cards, versions, kept}, state) do
    with :ok <- stores_exist(state.db, [store]) do
      p = %{"store" => store}

      homed =
        paged(
          state.db,
          "MATCH (g:Glider {known: true})-[:HOMED_IN]->(:Store {name: $store}) WHERE g.ref > $after RETURN g.ref, g.aloft ORDER BY g.ref LIMIT $page",
          p
        )

      also =
        paged(
          state.db,
          "MATCH (g:Glider {known: true})-[:ALSO_IN]->(:Store {name: $store}) WHERE g.ref > $after RETURN g.ref ORDER BY g.ref LIMIT $page",
          p
        )

      items = Enum.map(cards, &{&1, {:scan, store, Map.get(versions, &1.ref)}})

      with {:ok, tally} <- swept(state, put_all(state, items)) do
        listed = MapSet.new(Enum.map(cards, & &1.ref) ++ Map.keys(versions) ++ kept)
        gone = for [ref, aloft] <- homed, aloft != true, not MapSet.member?(listed, ref), do: ref
        stale = for [ref] <- also, not MapSet.member?(listed, ref), do: ref
        nodes = known_nodes(state.db, gone)
        {units, gc} = removals(nodes)

        unseen =
          for ref <- stale do
            [
              {"MATCH (g:Glider {ref: $ref})-[e:ALSO_IN]->(:Store {name: $store}) DELETE e",
               %{"ref" => ref, "store" => store}}
            ]
          end

        with :ok <- swept(state, run(state, units ++ unseen ++ gc_steps(gc))) do
          {:ok,
           %{
             added: tally.added,
             updated: tally.updated,
             removed: length(nodes),
             conflicts: Enum.sort(tally.conflicts)
           }}
        end
      end
    end
  end

  # A write of cards that failed part way may have left a draft or a node
  # nothing points at: clear them before answering.
  defp swept(state, {:error, _} = error) do
    _ = sweep(state.db)
    error
  end

  defp swept(_state, result), do: result

  defp stores_exist(db, names) do
    case Enum.find(
           names,
           &(rows!(db, "MATCH (s:Store {name: $name}) RETURN id(s) LIMIT 1", %{"name" => &1}) ==
               [])
         ) do
      nil -> :ok
      name -> {:error, "the catalog has no store #{inspect(name)}"}
    end
  end

  # ------------------------------------------------------------------ putting cards

  # Cards are put in groups. Each card is planned against what the file
  # holds, and against what the plans before it in its group will have
  # made (the cache); a group is as many plans as fit one write slice, and
  # is written before the next is planned, so a plan never relies on
  # something a write has not made yet or has since deleted.
  defp put_all(state, items),
    do: put_all(state, items, group(), %{added: 0, updated: 0, conflicts: []})

  defp put_all(state, [], group, tally) do
    with :ok <- flush(state, group), do: {:ok, tally}
  end

  defp put_all(state, [item | rest] = items, group, tally) do
    {plan, cache} = plan_card(state.db, item, group.cache)
    {bytes, n} = plan_cost(plan)

    cond do
      plan.steps == [] ->
        put_all(state, rest, %{group | cache: cache}, tally(tally, plan))

      group.bytes + bytes <= state.budget and group.n + n <= @max_statements ->
        group = %{
          group
          | steps: Enum.reverse(plan.steps, group.steps),
            gc: Map.merge(group.gc, plan.gc),
            bytes: group.bytes + bytes,
            n: group.n + n,
            cache: cache
        }

        put_all(state, rest, group, tally(tally, plan))

      group.steps != [] ->
        with :ok <- flush(state, group), do: put_all(state, items, group(), tally)

      true ->
        with :ok <- alone(state, item, plan),
             do: put_all(state, rest, group(), tally(tally, plan))
    end
  end

  defp group, do: %{steps: [], gc: %{}, bytes: 0, n: 0, cache: %{}}

  defp flush(_state, %{steps: [], gc: gc}) when map_size(gc) == 0, do: :ok
  defp flush(state, group), do: run(state, Enum.reverse(group.steps) ++ gc_steps(group.gc))

  defp tally(tally, %{outcome: :added}), do: %{tally | added: tally.added + 1}
  defp tally(tally, %{outcome: :updated}), do: %{tally | updated: tally.updated + 1}

  defp tally(tally, %{outcome: :conflict, ref: ref}),
    do: %{tally | conflicts: [ref | tally.conflicts]}

  defp tally(tally, _plan), do: tally

  # A card whose plan does not fit one slice. If its own statements do, they
  # take a slice and the deletions after them spill into the next; nothing
  # is planned until they are done. Otherwise it is built as a draft.
  defp alone(state, item, plan) do
    {bytes, n} = steps_cost(plan.steps)

    if bytes <= state.budget and n <= @max_statements,
      do: run(state, plan.steps ++ gc_steps(plan.gc)),
      else: draft(state, item)
  end

  # What to do for one card: `how` is `:put`, or `{:scan, store, version}`
  # for a card a scan of that store found.
  defp plan_card(db, {card, how}, cache) do
    {now, cache} = holding(db, card.ref, cache)

    case {how, now} do
      {{:scan, store, version}, {:known, _node, %{home: home} = homes}} when home != store ->
        {conflict(card.ref, store, version, homes), cache}

      {{:scan, _, _}, {:known, %Glider.Node{props: %{"aloft" => true}}, _}} ->
        {%{steps: [], gc: %{}, outcome: :untouched, ref: card.ref}, cache}

      _ ->
        upsert(db, card, now, version(how, now, card), cache)
    end
  end

  defp upsert(db, card, now, version, cache) do
    if same?(now, card) do
      {%{steps: refresh(card.ref, now, version), gc: %{}, outcome: :same, ref: card.ref}, cache}
    else
      {creates, cache} = creations(db, card, cache)

      unit =
        creates ++
          node_writes(card, now) ++ home_writes(card, now, version) ++ edge_writes(card, now)

      outcome = if match?({:known, _, _}, now), do: :updated, else: :added

      {%{steps: [unit], gc: leftovers(card, now), outcome: outcome, ref: card.ref},
       Map.put(cache, {:ref, card.ref}, :known)}
    end
  end

  defp same?({:known, node, homes}, card), do: card_from(node, homes.home) === card
  defp same?(_now, _card), do: false

  # What HOMED_IN's version should say once the card is written: a scan
  # says; a put keeps what a scan said while the home stays the same.
  defp version(:put, {:known, _, %{home: home}}, %Card{store: home}), do: :keep
  defp version(:put, _now, _card), do: {:set, nil}
  defp version({:scan, _, version}, _now, _card), do: {:set, version}

  defp refresh(ref, {:known, _, %{version: stored}}, {:set, version}) when version !== stored,
    do: [[set_version(ref, version)]]

  defp refresh(_ref, _now, _version), do: []

  defp set_version(ref, version) do
    {"MATCH (g:Glider {ref: $ref})-[e:HOMED_IN]->() SET e.version = $version",
     %{"ref" => ref, "version" => version}}
  end

  # A ref homed in another store, seen by a scan of this one.
  defp conflict(ref, store, version, homes) do
    p = %{"ref" => ref, "store" => store, "version" => version}

    steps =
      case Map.fetch(homes.also, store) do
        {:ok, ^version} ->
          []

        {:ok, _} ->
          [
            [
              {"MATCH (g:Glider {ref: $ref})-[e:ALSO_IN]->(:Store {name: $store}) SET e.version = $version",
               p}
            ]
          ]

        :error ->
          [
            [
              {"MATCH (g:Glider {ref: $ref}), (s:Store {name: $store}) CREATE (g)-[:ALSO_IN {version: $version}]->(s)",
               p}
            ]
          ]
      end

    %{steps: steps, gc: %{}, outcome: :conflict, ref: ref}
  end

  # What the file holds for a ref: nothing, a stub, or a known glider with
  # where it is kept. A stub this group's plans make is a stub already.
  defp holding(db, ref, cache) do
    if Map.get(cache, {:ref, ref}) == :stub do
      {:stub, cache}
    else
      case rows!(db, "MATCH (g:Glider {ref: $ref}) RETURN g", %{"ref" => ref}) do
        [] ->
          {:none, cache}

        [[%Glider.Node{props: %{"known" => true}} = node] | _] ->
          {{:known, node, homes(db, ref)}, cache}

        [[_stub] | _] ->
          {:stub, cache}
      end
    end
  end

  # Every edge from a glider to a store is HOMED_IN or ALSO_IN. The pattern
  # names neither: glider matches nothing for `[e:A|:B]` while one of the
  # types has never been written.
  defp homes(db, ref) do
    db
    |> rows!(
      "MATCH (g:Glider {ref: $ref})-[e]->(s:Store) RETURN type(e), s.name, e.version",
      %{"ref" => ref}
    )
    |> Enum.reduce(%{home: nil, version: nil, also: %{}}, fn
      ["HOMED_IN", name, version], acc -> %{acc | home: name, version: version}
      ["ALSO_IN", name, version], acc -> %{acc | also: Map.put(acc.also, name, version)}
    end)
  end

  # The shared nodes and stubs a card names that the file does not have yet.
  defp creations(db, card, cache) do
    {names, cache} =
      Enum.flat_map_reduce(@shared, cache, fn {field, label}, cache ->
        {missing, cache} = missing_names(db, label, names(card, field), cache)
        {create_all(label, "name", missing, ""), cache}
      end)

    {stubs, cache} = missing_stubs(db, card, cache)
    {names ++ create_all("Glider", "ref", stubs, ", known: false"), cache}
  end

  # Names not yet in the file are created by this plan, so from here on the
  # cache holds every name the group's plans can rely on.
  defp missing_names(db, label, names, cache) do
    unknown = names |> Enum.uniq() |> Enum.reject(&Map.has_key?(cache, {label, &1}))
    there = present(db, label, "name", unknown)
    missing = Enum.reject(unknown, &Map.has_key?(there, &1))
    {missing, Enum.reduce(unknown, cache, &Map.put(&2, {label, &1}, true))}
  end

  defp missing_stubs(db, card, cache) do
    unknown = card |> targets() |> Enum.reject(&Map.has_key?(cache, {:ref, &1}))
    there = present(db, "Glider", "ref", unknown)
    missing = Enum.reject(unknown, &Map.has_key?(there, &1))

    cache =
      Enum.reduce(unknown, cache, fn ref, cache ->
        Map.put(cache, {:ref, ref}, if(there[ref] == true, do: :known, else: :stub))
      end)

    {missing, cache}
  end

  # Which of `values` the file has as `label` nodes, with each one's `known`.
  # A lookup each, or one pass over the label when it is small enough that
  # the pass costs less than the lookups would.
  defp present(db, label, key, values) when length(values) > 4 do
    total =
      case rows!(db, "MATCH (x:#{label}) RETURN count(x)", %{}) do
        [[n]] -> n
        [] -> 0
      end

    if total * length(values) <= 2_000_000 do
      db
      |> rows!("MATCH (x:#{label}) WHERE x.#{key} IN $values RETURN x.#{key}, x.known", %{
        "values" => values
      })
      |> Map.new(fn [value, known] -> {value, known} end)
    else
      look_up(db, label, key, values)
    end
  end

  defp present(db, label, key, values), do: look_up(db, label, key, values)

  defp look_up(db, label, key, values) do
    for value <- values,
        [known] <-
          rows!(db, "MATCH (x:#{label} {#{key}: $v}) RETURN x.known LIMIT 1", %{"v" => value}),
        into: %{},
        do: {value, known}
  end

  defp node_writes(card, :none), do: [create_one("Glider", [{"ref", card.ref} | props(card)])]
  defp node_writes(card, :stub), do: set_props(glider(card.ref), props(card))

  defp node_writes(card, {:known, %Glider.Node{props: stored}, _homes}) do
    changed = Enum.reject(props(card), fn {k, v} -> Map.fetch(stored, k) === {:ok, v} end)
    dropped = attr_names(stored) -- Map.keys(card.attrs)
    set_props(glider(card.ref), changed) ++ remove_props(glider(card.ref), dropped)
  end

  defp home_writes(
         %Card{store: home} = card,
         {:known, _node, %{home: home, version: stored}},
         version
       ) do
    case version do
      {:set, v} when v !== stored -> [set_version(card.ref, v)]
      _ -> []
    end
  end

  # A new home. `version/3` keeps the version only while the home stays.
  defp home_writes(card, now, {:set, v}) do
    p = %{"ref" => card.ref, "store" => card.store, "version" => v}

    leave =
      case now do
        {:known, _node, homes} ->
          [{"MATCH (g:Glider {ref: $ref})-[e:HOMED_IN]->() DELETE e", %{"ref" => card.ref}}] ++
            if(Map.has_key?(homes.also, card.store),
              do: [
                {"MATCH (g:Glider {ref: $ref})-[e:ALSO_IN]->(:Store {name: $store}) DELETE e", p}
              ],
              else: []
            )

        _ ->
          []
      end

    leave ++
      [
        {"MATCH (g:Glider {ref: $ref}), (s:Store {name: $store}) CREATE (g)-[:HOMED_IN {version: $version}]->(s)",
         p}
      ]
  end

  # Edges of a kind the card changed are dropped and made again; the rest
  # stay as they are.
  defp edge_writes(card, now) do
    old = old_card(now)

    Enum.flat_map(@edges, fn {field, _label, _key, rel, _counted} = kind ->
      cond do
        old == nil ->
          link(glider(card.ref), kind, card)

        Map.fetch!(old, field) === Map.fetch!(card, field) ->
          []

        true ->
          [{"MATCH (g:Glider {ref: $ref})-[e:#{rel}]->() DELETE e", %{"ref" => card.ref}}] ++
            link(glider(card.ref), kind, card)
      end
    end)
  end

  defp old_card({:known, node, homes}), do: card_from(node, homes.home)
  defp old_card(_now), do: nil

  # What the card that was there pointed at and this one does not.
  defp leftovers(card, {:known, node, homes}), do: dropped(card_from(node, homes.home), card)
  defp leftovers(_card, _now), do: %{}

  defp dropped(old, new) do
    names =
      for {field, label} <- @shared,
          name <- MapSet.difference(MapSet.new(names(old, field)), MapSet.new(names(new, field))),
          into: %{} do
        {{label, name},
         {"MATCH (x:#{label} {name: $n}) WHERE degree(x) = 0 DELETE x", %{"n" => name}}}
      end

    stubs =
      for ref <- MapSet.difference(MapSet.new(targets(old)), MapSet.new(targets(new))),
          into: %{} do
        {{:stub, ref},
         {"MATCH (x:Glider {ref: $n, known: false}) WHERE indegree(x) = 0 DELETE x",
          %{"n" => ref}}}
      end

    Map.merge(names, stubs)
  end

  defp gc_steps(gc), do: gc |> Enum.sort() |> Enum.map(fn {_key, statement} -> [statement] end)

  # Taking a known glider's card away: its edges out go, and the node with
  # them unless something links to it, in which case it is a stub again.
  defp removals(nodes) do
    Enum.reduce(nodes, {[], %{}}, fn %Glider.Node{props: p} = node, {units, gc} ->
      ref = p["ref"]
      names = Enum.map_join((@fields -- ["known"]) ++ attr_names(p), ", ", &"g.#{ident!(&1)}")

      unit = [
        {"MATCH (g:Glider {ref: $ref})-[e]->() DELETE e", %{"ref" => ref}},
        {"MATCH (g:Glider {ref: $ref}) WHERE indegree(g) = 0 DELETE g", %{"ref" => ref}},
        {"MATCH (g:Glider {ref: $ref}) REMOVE #{names}", %{"ref" => ref}},
        {"MATCH (g:Glider {ref: $ref}) SET g.known = false", %{"ref" => ref}}
      ]

      {units ++ [unit], Map.merge(gc, dropped(card_from(node, nil), nil))}
    end)
  end

  # ------------------------------------------------------------------ drafts

  # A card too large for one slice is built beside the catalog as a :Draft,
  # one statement to a step, so any slice boundary between them is safe:
  # nothing that matches :Glider sees a draft, and a draft has no ref and
  # no home. The last step, one slice, moves the links into the old node
  # across to the draft, carries the old node's ALSO_IN, deletes the old
  # node and makes the draft a :Glider.
  defp draft(state, {card, how}) do
    id = System.unique_integer([:positive])
    {now, cache} = holding(state.db, card.ref, %{})

    version =
      case version(how, now, card) do
        :keep -> with {:known, _, homes} <- now, do: homes.version
        {:set, v} -> v
      end

    node = {"(g:Draft {draft: $draft})", %{"draft" => id}}
    {creates, _cache} = creations(state.db, card, cache)

    with {:ok, sets} <- set_chunks(node, props(card), state.budget) do
      build =
        creates ++
          [{"CREATE (:Draft {draft: $draft})", %{"draft" => id}}] ++
          sets ++ Enum.flat_map(@edges, &link(node, &1, card))

      steps = Enum.map(build, &[&1]) ++ [swap(card, now, version, id)]
      run(state, steps ++ gc_steps(leftovers(card, now)))
    end
  end

  defp swap(card, now, version, id) do
    p = %{"ref" => card.ref, "draft" => id, "store" => card.store, "version" => version}

    repoint =
      {"MATCH (a)-[:LINKS_TO]->(o:Glider {ref: $ref}), (n:Draft {draft: $draft}) CREATE (a)-[:LINKS_TO]->(n)",
       p}

    carry =
      {"MATCH (o:Glider {ref: $ref})-[e:ALSO_IN]->(s:Store), (n:Draft {draft: $draft}) WHERE s.name <> $store CREATE (n)-[:ALSO_IN {version: e.version}]->(s)",
       p}

    old =
      case now do
        :none -> []
        :stub -> [repoint, {"MATCH (o:Glider {ref: $ref}) DELETE o", p}]
        {:known, _, _} -> [repoint, carry, {"MATCH (o:Glider {ref: $ref}) DELETE o", p}]
      end

    old ++
      [
        {"MATCH (n:Draft {draft: $draft}), (s:Store {name: $store}) CREATE (n)-[:HOMED_IN {version: $version}]->(s)",
         p},
        {"MATCH (n:Draft {draft: $draft}) SET n:Glider, n.ref = $ref", p},
        {"MATCH (n:Glider {ref: $ref}) REMOVE n:Draft, n.draft", p}
      ]
  end

  # SET statements that each fit a slice, as few as will.
  defp set_chunks(node, props, budget) do
    props
    |> Enum.reduce_while({:ok, [], []}, fn {key, _} = prop, {:ok, done, current} ->
      cond do
        statement_cost(set_one(node, Enum.reverse([prop | current]))) <= budget ->
          {:cont, {:ok, done, [prop | current]}}

        current != [] and statement_cost(set_one(node, [prop])) <= budget ->
          {:cont, {:ok, [set_one(node, Enum.reverse(current)) | done], [prop]}}

        true ->
          {:halt, {:error, "the card's #{key} is more than one write slice holds"}}
      end
    end)
    |> case do
      {:ok, done, []} -> {:ok, Enum.reverse(done)}
      {:ok, done, current} -> {:ok, Enum.reverse([set_one(node, Enum.reverse(current)) | done])}
      error -> error
    end
  end

  # ------------------------------------------------------------------ statements

  defp glider(ref), do: {"(g:Glider {ref: $ref})", %{"ref" => ref}}

  # CREATE (:Label {name: $n0}), (:Label {name: $n1}), ...
  defp create_all(label, key, values, extra) do
    values
    |> Enum.chunk_every(@per_statement)
    |> Enum.map(fn chunk ->
      indexed = Enum.with_index(chunk)

      nodes =
        Enum.map_join(indexed, ", ", fn {_, i} -> "(:#{label} {#{key}: $n#{i}#{extra}})" end)

      {"CREATE " <> nodes, Map.new(indexed, fn {value, i} -> {"n#{i}", value} end)}
    end)
  end

  defp create_one(label, props) do
    indexed = Enum.with_index(props)
    body = Enum.map_join(indexed, ", ", fn {{key, _}, i} -> "#{ident!(key)}: $p#{i}" end)

    {"CREATE (g:#{label} {#{body}})",
     Map.new(indexed, fn {{_, value}, i} -> {"p#{i}", value} end)}
  end

  defp set_props(_node, []), do: []
  defp set_props(node, props), do: [set_one(node, props)]

  defp set_one({pattern, params}, props) do
    indexed = Enum.with_index(props)
    sets = Enum.map_join(indexed, ", ", fn {{key, _}, i} -> "g.#{ident!(key)} = $p#{i}" end)

    {"MATCH #{pattern} SET #{sets}",
     Enum.reduce(indexed, params, fn {{_, value}, i}, acc -> Map.put(acc, "p#{i}", value) end)}
  end

  defp remove_props(_node, []), do: []

  defp remove_props({pattern, params}, keys),
    do: [{"MATCH #{pattern} REMOVE " <> Enum.map_join(keys, ", ", &"g.#{ident!(&1)}"), params}]

  # The edges of one kind from a node to what the card names.
  defp link({pattern, params} = node, {field, label, key, rel, counted?}, card) do
    edges =
      card
      |> items(field)
      |> Enum.chunk_every(@per_statement)
      |> Enum.map(fn chunk ->
        indexed = Enum.with_index(chunk)
        ends = Enum.map_join(indexed, ", ", fn {_, i} -> "(x#{i}:#{label} {#{key}: $n#{i}})" end)

        creates =
          Enum.map_join(indexed, ", ", fn {_, i} ->
            if counted?,
              do: "(g)-[:#{rel} {count: $c#{i}}]->(x#{i})",
              else: "(g)-[:#{rel}]->(x#{i})"
          end)

        values =
          Enum.reduce(indexed, params, fn {{name, count}, i}, acc ->
            acc = Map.put(acc, "n#{i}", name)
            if counted?, do: Map.put(acc, "c#{i}", count), else: acc
          end)

        {"MATCH #{pattern}, #{ends} CREATE #{creates}", values}
      end)

    edges ++ if(field == :links and card.ref in card.links, do: self_link(node), else: [])
  end

  defp self_link({pattern, params}),
    do: [{"MATCH #{pattern} CREATE (g)-[:LINKS_TO]->(g)", params}]

  # One edge for each name, so a label given twice is one edge, with the
  # first count; the node keeps the list as it was given.
  defp items(card, field) when field in [:labels, :types],
    do: card |> Map.fetch!(field) |> Enum.uniq_by(& &1.name) |> Enum.map(&{&1.name, &1.count})

  defp items(card, :tags), do: Enum.map(card.tags, &{&1, nil})
  defp items(card, :links), do: Enum.map(targets(card), &{&1, nil})

  defp names(nil, _field), do: []
  defp names(card, :tags), do: card.tags
  defp names(card, field), do: card |> Map.fetch!(field) |> Enum.map(& &1.name)

  # The other gliders a card links to: a link to itself needs no stub.
  defp targets(nil), do: []
  defp targets(card), do: card.links -- [card.ref]

  defp ident!(name) do
    if is_binary(name) and Regex.match?(@ident, name),
      do: name,
      else: raise(ArgumentError, "not a property name: #{inspect(name)}")
  end

  # ------------------------------------------------------------------ slices

  # Writes steps in order, in as few slices as they fit. A step is never
  # split between slices.
  defp run(state, steps) do
    with {:ok, slices} <- pack(steps, state.budget) do
      Enum.reduce_while(slices, :ok, fn slice, :ok ->
        case Glider.write_batch(state.db, slice) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp pack(steps, budget) do
    steps
    |> Enum.reduce_while({[], [], 0, 0}, fn step, {slices, slice, bytes, n} ->
      {b, k} = steps_cost([step])

      cond do
        b > budget or k > @max_statements ->
          {:halt,
           {:error, "a write of #{b} bytes is more than one write slice holds (#{budget})"}}

        bytes + b <= budget and n + k <= @max_statements ->
          {:cont, {slices, [step | slice], bytes + b, n + k}}

        true ->
          {:cont, {[join(slice) | slices], [step], b, k}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {slices, [], _, _} -> {:ok, Enum.reverse(slices)}
      {slices, slice, _, _} -> {:ok, Enum.reverse([join(slice) | slices])}
    end
  end

  defp join(reversed_steps), do: reversed_steps |> Enum.reverse() |> Enum.concat()

  defp plan_cost(plan) do
    {bytes, n} = steps_cost(plan.steps)
    {gc_bytes, gc_n} = steps_cost(gc_steps(plan.gc))
    {bytes + gc_bytes, n + gc_n}
  end

  defp steps_cost(steps) do
    for step <- steps, statement <- step, reduce: {0, 0} do
      {bytes, n} -> {bytes + statement_cost(statement), n + 1}
    end
  end

  # What glider_ex charges a statement in a write slice: 32 bytes for each
  # byte of its text, and for each parameter its name's bytes and 64 for
  # each value, plus the bytes of any text.
  @spec statement_cost(statement()) :: non_neg_integer()
  defp statement_cost({cypher, params}) do
    Enum.reduce(params, 32 * byte_size(cypher), fn {key, value}, acc ->
      acc + byte_size(key) + value_cost(value)
    end)
  end

  defp value_cost(value) when is_binary(value), do: 64 + byte_size(value)
  defp value_cost(value) when is_list(value), do: Enum.reduce(value, 64, &(value_cost(&1) + &2))
  defp value_cost(_value), do: 64

  # ------------------------------------------------------------------ nodes and cards

  # The properties a card is kept in, besides its ref: every field under its
  # own name, in the order of @fields, then its attrs under theirs.
  defp props(%Card{} = card) do
    [
      {"namespace", Ref.namespace(card.ref)},
      {"name", Ref.name(card.ref)},
      {"description", card.description},
      {"tags", card.tags},
      {"links", card.links},
      {"mode", card.mode},
      {"hot", card.hot},
      {"nodes", card.nodes},
      {"edges", card.edges},
      {"bytes", card.bytes},
      {"labels", flat(card.labels)},
      {"types", flat(card.types)},
      {"indexes", flat(card.indexes)},
      {"extensions", card.extensions},
      {"schema", card.schema},
      {"text", Card.text(card)},
      {"flight", card.flight},
      {"generation", card.generation},
      {"position", card.position},
      {"aloft", card.aloft},
      {"known", true},
      {"created_at", card.created_at},
      {"updated_at", card.updated_at},
      {"described_at", card.described_at},
      {"attr_names", card.attrs |> Map.keys() |> Enum.sort()}
    ] ++ Enum.sort(card.attrs)
  end

  defp flat(counts), do: Enum.flat_map(counts, &[&1.name, &1.count])

  defp card_from(%Glider.Node{props: p}, store) do
    %Card{
      ref: p["ref"],
      description: p["description"],
      tags: as_list(p["tags"]),
      attrs: Map.new(for k <- attr_names(p), Map.has_key?(p, k), do: {k, p[k]}),
      links: as_list(p["links"]),
      mode: p["mode"] || "auto",
      hot: p["hot"],
      nodes: p["nodes"] || 0,
      edges: p["edges"] || 0,
      bytes: p["bytes"] || 0,
      labels: counts(p["labels"]),
      types: counts(p["types"]),
      indexes: counts(p["indexes"]),
      extensions: as_list(p["extensions"]),
      schema: p["schema"],
      flight: p["flight"],
      generation: p["generation"],
      position: p["position"],
      created_at: p["created_at"],
      updated_at: p["updated_at"],
      described_at: p["described_at"],
      store: store,
      aloft: p["aloft"] == true
    }
  end

  defp attr_names(props),
    do: props |> Map.get("attr_names") |> as_list() |> Enum.filter(&ident?/1)

  defp ident?(name), do: is_binary(name) and Regex.match?(@ident, name)

  defp as_list(value) when is_list(value), do: value
  defp as_list(_value), do: []

  defp counts(value) when is_list(value) do
    value
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [name, count] -> [%{name: name, count: count}]
      _ -> []
    end)
  end

  defp counts(_value), do: []

  defp rows!(db, cypher, params) do
    case Glider.query(db, cypher, params) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> raise Glider.Error, message: reason, query: cypher
    end
  end

  # Every row of a query whose first column is `g.ref`, in ref order, a
  # page at a time. The query takes `$after` and `$page`.
  defp paged(db, cypher, params, after_ref \\ "", acc \\ []) do
    rows = rows!(db, cypher, Map.merge(params, %{"after" => after_ref, "page" => @page}))
    acc = Enum.reverse(rows, acc)

    if length(rows) < @page,
      do: Enum.reverse(acc),
      else: paged(db, cypher, params, rows |> List.last() |> hd(), acc)
  end

  # The nodes of the refs that are known gliders.
  defp known_nodes(db, refs) do
    for ref <- refs,
        [node] <- rows!(db, "MATCH (g:Glider {ref: $ref, known: true}) RETURN g", %{"ref" => ref}),
        do: node
  end

  # ------------------------------------------------------------------ listing

  @list_options [:store, :tag, :label, :type, :prefix, :where, :limit, :after]
  @filters [
    {:label, "Label", "HAS_LABEL"},
    {:type, "EdgeType", "HAS_TYPE"},
    {:tag, "Tag", "TAGGED"}
  ]

  # Chains anchored on an index come first: the matcher walks from each
  # chain's cheapest node, and binds `g` for the chains after it.
  defp list_query(opts) do
    with :ok <- known_options(opts, @list_options),
         {:ok, limit} <- limit_option(Keyword.get(opts, :limit, @limit)),
         {:ok, names} <- name_options(opts, [:store, :tag, :label, :type]),
         {:ok, prefix} <- prefix_option(Keyword.get(opts, :prefix)),
         {:ok, after_ref} <- after_option(Keyword.get(opts, :after)),
         {:ok, where} <- where_option(Keyword.get(opts, :where, %{})) do
      filters =
        for {key, label, rel} <- @filters, Map.has_key?(names, key) do
          fn g -> "(:#{label} {name: $#{key}})<-[:#{rel}]-(#{g})" end
        end

      home =
        if Map.has_key?(names, :store),
          do: fn g -> "(s:Store {name: $store})<-[:HOMED_IN]-(#{g})" end,
          else: fn g -> "(#{g})-[:HOMED_IN]->(s:Store)" end

      [first | rest] = filters ++ [home]
      chains = [first.("g:Glider {known: true}") | Enum.map(rest, & &1.("g"))]

      conditions =
        if(after_ref, do: ["g.ref > $after"], else: []) ++
          if(prefix, do: ["(g.ref = $prefix OR g.ref STARTS WITH $under)"], else: []) ++
          for {{name, _}, i} <- Enum.with_index(where), do: "g.#{ident!(name)} = $w#{i}"

      cypher =
        "MATCH #{Enum.join(chains, ", ")}" <>
          if(conditions == [], do: "", else: " WHERE " <> Enum.join(conditions, " AND ")) <>
          " RETURN g.ref ORDER BY g.ref LIMIT $limit"

      params =
        names
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.put("limit", limit + 1)
        |> put_if(after_ref, "after", after_ref)
        |> put_if(prefix, "prefix", prefix)
        |> put_if(prefix, "under", prefix && prefix <> "/")
        |> Map.merge(Map.new(Enum.with_index(where), fn {{_, value}, i} -> {"w#{i}", value} end))

      {:ok, cypher, params, limit}
    end
  end

  defp put_if(map, nil, _key, _value), do: map
  defp put_if(map, _, key, value), do: Map.put(map, key, value)

  defp known_options(opts, allowed) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "options are a keyword list, got: #{inspect(opts, limit: 5)}"}

      unknown = Enum.find(Keyword.keys(opts), &(&1 not in allowed)) ->
        {:error, "#{inspect(unknown)} is not an option here; these are: #{inspect(allowed)}"}

      true ->
        :ok
    end
  end

  defp limit_option(n) when is_integer(n) and n > 0, do: {:ok, min(n, @max_limit)}
  defp limit_option(other), do: {:error, "limit is a number of gliders, got: #{inspect(other)}"}

  defp top_option(n) when is_integer(n) and n > 0, do: {:ok, min(n, @max_top)}
  defp top_option(other), do: {:error, "top is a number of gliders, got: #{inspect(other)}"}

  defp name_options(opts, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Keyword.fetch(opts, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} when is_binary(value) and byte_size(value) <= @max_name ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {:ok, other} ->
          {:halt, {:error, "#{key} is a name, got: #{inspect(other, limit: 5)}"}}
      end
    end)
  end

  defp prefix_option(nil), do: {:ok, nil}

  defp prefix_option(prefix) when is_binary(prefix) do
    case String.trim_trailing(prefix, "/") do
      "" ->
        {:ok, nil}

      trimmed ->
        with {:error, reason} <- Ref.parse(trimmed), do: {:error, "prefix: " <> reason}
    end
  end

  defp prefix_option(other), do: {:error, "prefix is a ref prefix, got: #{inspect(other)}"}

  defp after_option(nil), do: {:ok, nil}

  defp after_option(ref) do
    with {:error, reason} <- Ref.parse(ref), do: {:error, "after: " <> reason}
  end

  defp where_option(where) do
    if (is_map(where) or Keyword.keyword?(where)) and Enum.count(where) <= @max_where do
      where
      |> Enum.map(fn {k, v} -> {if(is_atom(k), do: Atom.to_string(k), else: k), v} end)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, acc} ->
        cond do
          not ident?(name) or name in Card.reserved() ->
            {:halt, {:error, "where: #{inspect(name)} is not an attr name"}}

          not attr_value?(value) ->
            {:halt, {:error, "where: #{inspect(name)} is not compared with a flat value"}}

          true ->
            {:cont, {:ok, [{name, value} | acc]}}
        end
      end)
      |> case do
        {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
        error -> error
      end
    else
      {:error,
       "where is a map of at most #{@max_where} attr names to values, got: #{inspect(where, limit: 5)}"}
    end
  end

  # ------------------------------------------------------------------ checking input

  defp check_store(%{name: name, kind: kind, url: url} = store) do
    cas = Map.get(store, :cas)
    scanned_at = Map.get(store, :scanned_at)

    cond do
      not (is_binary(name) and name != "" and byte_size(name) <= 255 and String.valid?(name)) ->
        {:error, "a store's name is text of 1 to 255 bytes, got: #{inspect(name)}"}

      kind_name(kind) == nil ->
        {:error, "a store's kind is :file, :dir, :s3 or :peer, got: #{inspect(kind)}"}

      not (is_binary(url) and byte_size(url) <= 4_096 and String.valid?(url)) ->
        {:error, "a store's url is text of at most 4096 bytes"}

      cas not in [true, false, nil] ->
        {:error, "a store's cas is true, false or nil, got: #{inspect(cas)}"}

      not (is_nil(scanned_at) or int?(scanned_at)) ->
        {:error, "a store's scanned_at is unix seconds, got: #{inspect(scanned_at)}"}

      true ->
        {:ok,
         %{
           name: name,
           kind: kind_name(kind),
           url: strip_userinfo(url),
           cas: cas,
           scanned_at: scanned_at
         }}
    end
  end

  defp check_store(other),
    do: {:error, "a store is a map with name, kind and url, got: #{inspect(other, limit: 5)}"}

  defp kind_name(kind) when is_atom(kind) and kind != nil do
    name = Atom.to_string(kind)
    if Map.has_key?(@kinds, name), do: name
  end

  defp kind_name(kind) when is_binary(kind), do: if(Map.has_key?(@kinds, kind), do: kind)
  defp kind_name(_kind), do: nil

  defp strip_userinfo(url) do
    case URI.parse(url) do
      %URI{userinfo: info} = uri when is_binary(info) -> URI.to_string(%{uri | userinfo: nil})
      _ -> url
    end
  end

  # A card from outside, checked as `Aerotow.Card` checks one read from a
  # store, and for what glider can hold. The fields somebody sets are put
  # through `Aerotow.Card.new/2`, so they come out as Card keeps them.
  defp check_card(%Card{} = card) do
    with {:ok, base} <-
           Card.new(card.ref,
             description: card.description,
             tags: card.tags,
             attrs: card.attrs,
             links: card.links,
             mode: card.mode,
             hot: card.hot
           ),
         {:ok, labels} <- check_counts(card.labels, "labels"),
         {:ok, types} <- check_counts(card.types, "types"),
         {:ok, indexes} <- check_counts(card.indexes, "indexes"),
         :ok <- check_extensions(card.extensions),
         :ok <- check_text(card.schema, "schema", 262_144),
         :ok <- check_text(card.generation, "generation", 64),
         :ok <- check_numbers(card),
         :ok <- check_attr_numbers(base.attrs) do
      cond do
        not (is_binary(card.store) and card.store != "") ->
          {:error, "a card's store names the store it is homed in, got: #{inspect(card.store)}"}

        not is_boolean(card.aloft) ->
          {:error, "aloft is true or false, got: #{inspect(card.aloft)}"}

        true ->
          checked = %{
            base
            | nodes: card.nodes,
              edges: card.edges,
              bytes: card.bytes,
              labels: labels,
              types: types,
              indexes: indexes,
              extensions: card.extensions,
              schema: card.schema,
              flight: card.flight,
              generation: card.generation,
              position: card.position,
              created_at: card.created_at,
              updated_at: card.updated_at,
              described_at: card.described_at,
              store: card.store,
              aloft: card.aloft
          }

          size = checked |> Card.encode() |> byte_size()

          if size <= @max_card,
            do: {:ok, checked},
            else: {:error, "a card of #{size} bytes is larger than a store holds (#{@max_card})"}
      end
    end
  end

  defp check_card(other), do: {:error, "not a card: #{inspect(other, limit: 5)}"}

  defp check_counts(list, what) when is_list(list) and length(list) <= @max_counts do
    list
    |> Enum.reduce_while({:ok, []}, fn
      %{name: name, count: count}, {:ok, acc} ->
        if short_text?(name) and natural?(count),
          do: {:cont, {:ok, [%{name: name, count: count} | acc]}},
          else: {:halt, {:error, "#{what} is a list of %{name, count}"}}

      _, _ ->
        {:halt, {:error, "#{what} is a list of %{name, count}"}}
    end)
    |> case do
      {:ok, counts} -> {:ok, Enum.reverse(counts)}
      error -> error
    end
  end

  defp check_counts(_, what),
    do: {:error, "#{what} is a list of at most #{@max_counts} %{name, count}"}

  defp check_extensions(list) when is_list(list) and length(list) <= 256 do
    if Enum.all?(list, &(is_binary(&1) and byte_size(&1) <= 256 and String.valid?(&1))),
      do: :ok,
      else: {:error, "extensions is a list of names"}
  end

  defp check_extensions(_), do: {:error, "extensions is a list of names"}

  defp check_text(nil, _what, _max), do: :ok

  defp check_text(text, what, max) when is_binary(text) do
    if String.valid?(text) and byte_size(text) <= max,
      do: :ok,
      else: {:error, "#{what} is UTF-8 of at most #{max} bytes"}
  end

  defp check_text(_text, what, _max), do: {:error, "#{what} is text"}

  defp check_numbers(card) do
    checks = [
      {"nodes", card.nodes, &natural?/1},
      {"edges", card.edges, &natural?/1},
      {"bytes", card.bytes, &natural?/1},
      {"hot", card.hot, &maybe_natural?/1},
      {"flight", card.flight, &(is_nil(&1) or (natural?(&1) and &1 > 0))},
      {"position", card.position, &maybe_natural?/1},
      {"created_at", card.created_at, &maybe_natural?/1},
      {"updated_at", card.updated_at, &maybe_natural?/1},
      {"described_at", card.described_at, &maybe_natural?/1}
    ]

    case Enum.find(checks, fn {_, value, ok?} -> not ok?.(value) end) do
      nil -> :ok
      {what, value, _} -> {:error, "#{what} is not a number glider can hold: #{inspect(value)}"}
    end
  end

  defp check_attr_numbers(attrs) do
    case Enum.find(attrs, fn {_, v} -> is_integer(v) and not int?(v) end) do
      nil -> :ok
      {name, _} -> {:error, "attr #{inspect(name)} is an integer of more than 64 bits"}
    end
  end

  defp attr_value?(v) when is_binary(v), do: String.valid?(v) and byte_size(v) <= 4_096
  defp attr_value?(v) when is_integer(v), do: int?(v)
  defp attr_value?(v) when is_float(v) or is_boolean(v), do: true

  defp attr_value?(v) when is_list(v),
    do: length(v) <= 256 and Enum.all?(v, &(is_binary(&1) and attr_value?(&1)))

  defp attr_value?(_), do: false

  defp short_text?(v), do: is_binary(v) and byte_size(v) <= @max_name and String.valid?(v)
  defp int?(n), do: is_integer(n) and n >= @int_min and n <= @int_max
  defp natural?(n), do: is_integer(n) and n >= 0 and n <= @int_max
  defp maybe_natural?(n), do: is_nil(n) or natural?(n)
end
