defmodule Aerotow.Wire do
  @moduledoc """
  What crosses between two aerotows over HTTP: requests, answers and
  errors, to and from the JSON `Aerotow.Plug` serves and
  `Aerotow.Store.Peer` sends.

  A request is a term `Aerotow.Forward.serve/4` runs:

  | request | op | body |
  |---|---|---|
  | `{:gliders, opts}` | `gliders` | `{after, limit, prefix}` |
  | `{:card, ref}` | `card` | `{ref}` |
  | `{:create, ref, opts}` | `create` | `{ref, description, tags, attrs, links, store, mode, hot}` |
  | `{:update, ref, changes}` | `update` | `{ref, changes}` |
  | `{:delete, ref, opts}` | `delete` | `{ref, purge}` |
  | `{:query, ref, cypher, params, opts}` | `query` | `{ref, cypher, params, max_rows, max_bytes, graph}` |
  | `{:run, ref, cypher, params, opts}` | `run` | `{ref, cypher, params, sync}` |
  | `{:write_batch, ref, statements, opts}` | `batch` | `{ref, statements: [[cypher, params]], sync}` |
  | `{:context, ref, opts}` | `context` | `{ref, …retrieve options}` |
  | `{:schema, ref}`, `{:stats, ref}` | `schema`, `stats` | `{ref}` |
  | `{:find, cypher, params}` | `find` | `{cypher, params}` |
  | `{:search, text, opts}` | `search` | `{query, top}` |

  ## Values

  Glider's values travel as JSON values: `null`, booleans, integers,
  floats, text and lists, nested as deep as 32 levels. A float stays a
  float (`3.0` is written `3.0`), and text is always a JSON string, so text
  that looks like an object is still text. Every JSON object in a value's
  place is tagged with `"_e"`:

    * `{"_e": "node", "id", "labels", "props"}` is a `%Glider.Node{}`
    * `{"_e": "rel", "id", "type", "from", "to", "props"}` is a `%Glider.Rel{}`
    * `{"_e": "map", "v": {…}}` is a map with text keys

  and an object without a tag, or with another one, is refused. Nothing
  read here becomes an atom: the atoms this module gives back (option names,
  the keys of a schema or a context result) are written in this file and
  chosen by matching text.

  ## Errors

  An error is `{"error": message, "code": code}`, with these statuses:

  | code | status | reason |
  |---|---|---|
  | `bad_request` | 400 | a body that is not a request of its op |
  | `unauthorized` | 401 | no token, or one that is not taken |
  | `forbidden` | 403 | `authorize` said no |
  | `unknown_op` | 404 | a path that is no op |
  | `not_found` | 404 | `:not_found` |
  | `method_not_allowed` | 405 | `GET` of an op, `POST` of `/v1` |
  | `exists` | 409 | `:exists` |
  | `aloft_elsewhere` | 409 | `{:aloft_elsewhere, holder}`, with `holder` |
  | `runs_on_peer` | 409 | `{:runs_on_peer, store}`, with `store` |
  | `purging` | 409 | `:purging` |
  | `too_large` | 413 | a body over the plug's `max_body` |
  | `refused` | 422 | a reason a person reads: a statement that is not a read, a bad option, glider's own error |
  | `too_many_hops` | 508 | `:too_many_hops` |
  | `store_unavailable` | 503 | `{:store_unavailable, name, reason}`, with `store` |
  | `peer_unavailable` | 503 | `{:peer_unavailable, name, reason}`, from a peer further on |
  | `outcome_unknown` | 503 | `{:outcome_unknown, name, reason}`, from a peer further on |
  | `unavailable` | 503 | `:not_running`, `:too_many_aloft`, `:lost`, `:landing`, `:no_cas` |
  | `timeout` | 504 | `:timeout` |
  | `error` | 500 | anything else, as text |

  `decode_error/2` gives the reason back from these.
  """

  alias Aerotow.{Card, Ref}

  @max_depth 32

  @ops %{
    "gliders" => :gliders,
    "card" => :card,
    "create" => :create,
    "update" => :update,
    "delete" => :delete,
    "query" => :query,
    "run" => :run,
    "batch" => :write_batch,
    "context" => :context,
    "schema" => :schema,
    "stats" => :stats,
    "find" => :find,
    "search" => :search
  }

  @names Map.new(@ops, fn {name, op} -> {op, name} end)

  # The options of Glider.Context.retrieve/2, as text, to the atoms they are.
  @retrieve Map.new(
              ~w(query seeds budget depth types type dir labels props exclude seen format alpha
                 normalize max_chars max_fanout epsilon top label keys)a,
              &{Atom.to_string(&1), &1}
            )

  @unavailable ~w(not_running too_many_aloft lost landing no_cas)a

  @typedoc "A request, as `Aerotow.Forward.serve/4` runs it."
  @type request ::
          {:gliders, keyword()}
          | {:card, Ref.t()}
          | {:create, Ref.t(), keyword()}
          | {:update, Ref.t(), map()}
          | {:delete, Ref.t(), keyword()}
          | {:query, Ref.t(), String.t(), map(), keyword()}
          | {:run, Ref.t(), String.t(), map(), keyword()}
          | {:write_batch, Ref.t(), [{String.t(), map()}], keyword()}
          | {:context, Ref.t(), keyword()}
          | {:schema, Ref.t()}
          | {:stats, Ref.t()}
          | {:find, String.t(), map()}
          | {:search, String.t(), keyword()}

  @typedoc "A request's op, as a term: the first element of the request."
  @type op ::
          :gliders
          | :card
          | :create
          | :update
          | :delete
          | :query
          | :run
          | :write_batch
          | :context
          | :schema
          | :stats
          | :find
          | :search

  # ------------------------------------------------------------------ ops

  @doc """
  The op a path segment names, or `:error`.

      iex> Aerotow.Wire.op("batch")
      {:ok, :write_batch}

      iex> Aerotow.Wire.op("drop")
      :error
  """
  @spec op(String.t()) :: {:ok, op()} | :error
  def op(name) when is_binary(name), do: Map.fetch(@ops, name)
  def op(_), do: :error

  @doc "The path segment of an op: `name(:write_batch)` is `\"batch\"`."
  @spec name(op()) :: String.t()
  def name(op), do: Map.fetch!(@names, op)

  @doc "Every op's path segment."
  @spec names() :: [String.t()]
  def names, do: @ops |> Map.keys() |> Enum.sort()

  @doc """
  Whether an op only reads, and so may be sent again when its answer was
  lost. `create`, `update`, `delete`, `run` and `batch` write.
  """
  @spec read?(op()) :: boolean()
  def read?(op), do: op not in [:create, :update, :delete, :run, :write_batch]

  @doc "The ref a request is for, or `nil` for one that is about the catalog."
  @spec ref(request()) :: Ref.t() | nil
  def ref({op, _}) when op in [:gliders], do: nil
  def ref({op, _, _}) when op in [:find, :search], do: nil
  def ref(request), do: elem(request, 1)

  # ------------------------------------------------------------------ requests

  @doc """
  A request as its op's path segment and a body to send as JSON. A value
  that cannot be sent (a pid, text that is not UTF-8) is an error.
  """
  @spec encode_request(request()) :: {:ok, String.t(), map()} | {:error, String.t()}
  def encode_request(request) do
    {:ok, name(elem(request, 0)), request_body(request)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp request_body({:gliders, opts}),
    do: compact(%{"after" => opts[:after], "limit" => opts[:limit], "prefix" => opts[:prefix]})

  defp request_body({op, ref}) when op in [:card, :schema, :stats], do: %{"ref" => ref}

  defp request_body({:create, ref, opts}) do
    fields = Keyword.take(opts, [:description, :tags, :attrs, :links, :mode, :hot, :store])

    Map.new(fields, fn {k, v} -> {Atom.to_string(k), plain(v)} end)
    |> Map.put("ref", ref)
  end

  defp request_body({:update, ref, changes}),
    do: %{"ref" => ref, "changes" => Map.new(changes, fn {k, v} -> {to_string(k), plain(v)} end)}

  defp request_body({:delete, ref, opts}),
    do: %{"ref" => ref, "purge" => Keyword.get(opts, :purge, false)}

  defp request_body({:query, ref, cypher, params, opts}) do
    compact(%{
      "ref" => ref,
      "cypher" => cypher,
      "params" => encode_params(params),
      "max_rows" => opts[:max_rows],
      "max_bytes" => opts[:max_bytes],
      "graph" => opts[:graph]
    })
  end

  defp request_body({:run, ref, cypher, params, opts}) do
    compact(%{
      "ref" => ref,
      "cypher" => cypher,
      "params" => encode_params(params),
      "sync" => sync_text(opts[:sync])
    })
  end

  defp request_body({:write_batch, ref, statements, opts}) do
    compact(%{
      "ref" => ref,
      "statements" =>
        Enum.map(statements, fn {cypher, params} -> [cypher, encode_params(params)] end),
      "sync" => sync_text(opts[:sync])
    })
  end

  defp request_body({:context, ref, opts}) do
    opts
    |> Keyword.delete(:timeout)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), encode_value(option_value(v))} end)
    |> Map.put("ref", ref)
  end

  defp request_body({:find, cypher, params}),
    do: %{"cypher" => cypher, "params" => encode_params(params)}

  defp request_body({:search, text, opts}), do: compact(%{"query" => text, "top" => opts[:top]})

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  defp sync_text(nil), do: nil
  defp sync_text(sync) when is_atom(sync), do: Atom.to_string(sync)
  defp sync_text(other), do: other

  # A context option's atom value (format: :text) goes as its name.
  defp option_value(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp option_value(v), do: v

  # Card fields are JSON as they are; an atom (mode: :disk) goes as its name.
  defp plain(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)

  defp plain(v) when is_list(v),
    do: if(Keyword.keyword?(v) and v != [], do: plain(Map.new(v)), else: Enum.map(v, &plain/1))

  defp plain(%{} = v) when not is_struct(v),
    do: Map.new(v, fn {k, x} -> {to_string(k), plain(x)} end)

  defp plain(v) when is_binary(v), do: text!(v)
  defp plain(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp plain(v), do: raise(ArgumentError, "#{inspect(v, limit: 5)} cannot be sent to a peer")

  defp encode_params(params) when is_map(params) or is_list(params) do
    Map.new(params, fn {k, v} -> {to_string(k), encode_value(v)} end)
  end

  defp encode_params(other),
    do: raise(ArgumentError, "parameters are a map, got: #{inspect(other, limit: 5)}")

  @doc """
  Reads a request from its op and its decoded JSON body. Everything in it is
  checked; what is not a request of that op is `{:error, message}`. Refs are
  left for the receiving facade to parse, as a local caller's are.
  """
  @spec decode_request(op(), term()) :: {:ok, request()} | {:error, String.t()}
  def decode_request(op, body) when is_map(body) do
    request(op, body)
  catch
    {:bad, message} -> {:error, message}
  end

  def decode_request(_op, _body), do: {:error, "a request's body is a JSON object"}

  defp request(:gliders, b) do
    {:ok,
     {:gliders,
      optional(after: text(b, "after"), limit: integer(b, "limit"), prefix: text(b, "prefix"))}}
  end

  defp request(op, b) when op in [:card, :schema, :stats], do: {:ok, {op, required(b, "ref")}}

  defp request(:create, b) do
    known!(b, ~w(ref description tags attrs links mode hot store))

    fields =
      for key <- ~w(description tags attrs links mode hot store), Map.has_key?(b, key) do
        {card_field(key), b[key]}
      end

    {:ok, {:create, required(b, "ref"), fields}}
  end

  defp request(:update, b) do
    case b["changes"] do
      %{} = changes -> {:ok, {:update, required(b, "ref"), changes}}
      _ -> bad("update takes changes, an object")
    end
  end

  defp request(:delete, b) do
    purge =
      case Map.get(b, "purge", false) do
        flag when is_boolean(flag) -> flag
        _ -> bad("purge is true or false")
      end

    {:ok, {:delete, required(b, "ref"), [purge: purge]}}
  end

  defp request(:query, b) do
    opts =
      optional(
        max_rows: integer(b, "max_rows"),
        max_bytes: integer(b, "max_bytes"),
        graph: boolean(b, "graph")
      )

    {:ok, {:query, required(b, "ref"), statement(b), params(b["params"]), opts}}
  end

  defp request(:run, b),
    do: {:ok, {:run, required(b, "ref"), statement(b), params(b["params"]), sync(b)}}

  defp request(:write_batch, b) do
    statements =
      case b["statements"] do
        list when is_list(list) ->
          Enum.map(list, fn
            [cypher, params] when is_binary(cypher) -> {cypher, params(params)}
            [cypher] when is_binary(cypher) -> {cypher, %{}}
            _ -> bad("statements is a list of [cypher, params]")
          end)

        _ ->
          bad("batch takes statements, a list of [cypher, params]")
      end

    {:ok, {:write_batch, required(b, "ref"), statements, sync(b)}}
  end

  defp request(:context, b) do
    opts =
      b
      |> Map.delete("ref")
      |> Enum.map(fn {key, value} ->
        case Map.fetch(@retrieve, key) do
          {:ok, name} -> {name, value!(value)}
          :error -> bad("#{inspect(key)} is not an option of context")
        end
      end)
      |> Enum.sort()

    case Keyword.get(opts, :format, "text") do
      "text" -> {:ok, {:context, required(b, "ref"), opts}}
      _ -> bad("context answers in its text form only, format: \"text\"")
    end
  end

  defp request(:find, b), do: {:ok, {:find, statement(b), params(b["params"])}}

  defp request(:search, b) do
    query =
      case b["query"] do
        q when is_binary(q) -> q
        _ -> bad("search takes query, text")
      end

    {:ok, {:search, query, optional(top: integer(b, "top"))}}
  end

  defp card_field("description"), do: :description
  defp card_field("tags"), do: :tags
  defp card_field("attrs"), do: :attrs
  defp card_field("links"), do: :links
  defp card_field("mode"), do: :mode
  defp card_field("hot"), do: :hot
  defp card_field("store"), do: :store

  defp known!(b, keys) do
    case Enum.reject(Map.keys(b), &(&1 in keys)) do
      [] -> :ok
      [key | _] -> bad("#{inspect(key)} is not a field of this request")
    end
  end

  defp required(b, key) do
    case b[key] do
      value when is_binary(value) -> value
      _ -> bad("#{key} is required, as text")
    end
  end

  defp statement(b) do
    case b["cypher"] do
      cypher when is_binary(cypher) -> cypher
      _ -> bad("cypher is required, as text")
    end
  end

  defp text(b, key) do
    case b[key] do
      nil -> nil
      value when is_binary(value) -> value
      _ -> bad("#{key} is text")
    end
  end

  defp integer(b, key) do
    case b[key] do
      nil -> nil
      n when is_integer(n) and n >= 0 -> n
      _ -> bad("#{key} is a whole number")
    end
  end

  defp boolean(b, key) do
    case b[key] do
      nil -> nil
      flag when is_boolean(flag) -> flag
      _ -> bad("#{key} is true or false")
    end
  end

  defp sync(b) do
    case b["sync"] do
      nil -> []
      "commit" -> [sync: :commit]
      _ -> bad("sync is \"commit\" or absent")
    end
  end

  defp optional(pairs), do: Enum.reject(pairs, fn {_, v} -> is_nil(v) end)

  defp params(nil), do: %{}

  defp params(%{} = params),
    do: Map.new(params, fn {k, v} -> {k, value!(v)} end)

  defp params(_), do: bad("params is an object")

  defp value!(json) do
    case decode_value(json) do
      {:ok, value} -> value
      {:error, message} -> bad(message)
    end
  end

  defp bad(message), do: throw({:bad, message})

  # ------------------------------------------------------------------ values

  @doc """
  A glider value as JSON: see the moduledoc. Raises `ArgumentError` for a
  term that is not one (a pid, an atom, text that is not UTF-8).

      iex> Aerotow.Wire.encode_value([1, 2.0, "{\\"_e\\": \\"node\\"}"])
      [1, 2.0, "{\\"_e\\": \\"node\\"}"]
  """
  @spec encode_value(term()) :: term()
  def encode_value(nil), do: nil
  def encode_value(v) when is_boolean(v) or is_number(v), do: v
  def encode_value(v) when is_binary(v), do: text!(v)
  def encode_value(v) when is_list(v), do: Enum.map(v, &encode_value/1)

  def encode_value(%Glider.Node{id: id, labels: labels, props: props}),
    do: %{"_e" => "node", "id" => id, "labels" => labels, "props" => encode_props(props)}

  def encode_value(%Glider.Rel{} = r),
    do: %{
      "_e" => "rel",
      "id" => r.id,
      "type" => r.type,
      "from" => r.from,
      "to" => r.to,
      "props" => encode_props(r.props)
    }

  def encode_value(%{} = map) when not is_struct(map),
    do: %{"_e" => "map", "v" => encode_props(map)}

  def encode_value(other),
    do: raise(ArgumentError, "#{inspect(other, limit: 5)} is not a value that can cross the wire")

  defp encode_props(props),
    do: Map.new(props, fn {k, v} -> {text!(to_string(k)), encode_value(v)} end)

  defp text!(s) do
    if String.valid?(s),
      do: s,
      else: raise(ArgumentError, "text that is not UTF-8 cannot cross the wire")
  end

  @doc """
  A glider value from JSON: see the moduledoc.

      iex> Aerotow.Wire.decode_value(%{"_e" => "node", "id" => 1, "labels" => ["A"], "props" => %{"x" => 3.0}})
      {:ok, %Glider.Node{id: 1, labels: ["A"], props: %{"x" => 3.0}}}

      iex> Aerotow.Wire.decode_value(%{"_e" => "node"})
      {:error, "a node is {_e, id, labels, props}"}
  """
  @spec decode_value(term()) :: {:ok, term()} | {:error, String.t()}
  def decode_value(json) do
    {:ok, value(json, 0)}
  catch
    {:bad, message} -> {:error, message}
  end

  defp value(_json, depth) when depth > @max_depth,
    do: bad("a value is nested more than #{@max_depth} levels deep")

  defp value(v, _depth) when is_nil(v) or is_boolean(v) or is_number(v) or is_binary(v), do: v
  defp value(list, depth) when is_list(list), do: Enum.map(list, &value(&1, depth + 1))

  defp value(%{"_e" => "node"} = m, depth) do
    case m do
      %{"id" => id, "labels" => labels, "props" => %{} = props}
      when is_integer(id) and id >= 0 and is_list(labels) and map_size(m) == 4 ->
        if Enum.all?(labels, &is_binary/1),
          do: %Glider.Node{id: id, labels: labels, props: props(props, depth)},
          else: bad("a node's labels are text")

      _ ->
        bad("a node is {_e, id, labels, props}")
    end
  end

  defp value(%{"_e" => "rel"} = m, depth) do
    case m do
      %{"id" => id, "type" => type, "from" => from, "to" => to, "props" => %{} = props}
      when is_integer(id) and id >= 0 and is_binary(type) and is_integer(from) and from >= 0 and
             is_integer(to) and to >= 0 and map_size(m) == 6 ->
        %Glider.Rel{id: id, type: type, from: from, to: to, props: props(props, depth)}

      _ ->
        bad("a relationship is {_e, id, type, from, to, props}")
    end
  end

  defp value(%{"_e" => "map", "v" => %{} = v} = m, depth) when map_size(m) == 2,
    do: props(v, depth)

  defp value(%{}, _depth),
    do: bad("an object in a value is a node, a relationship or a map, tagged with _e")

  defp props(props, depth), do: Map.new(props, fn {k, v} -> {k, value(v, depth + 1)} end)

  # ------------------------------------------------------------------ answers

  @doc "The answer to a request, as a body to send as JSON."
  @spec encode_answer(op(), term()) :: term()
  def encode_answer(:gliders, %{gliders: cards, next: next}),
    do: %{"gliders" => Enum.map(cards, &card_json/1), "next" => next}

  def encode_answer(op, %Card{} = card) when op in [:card, :create, :update], do: card_json(card)
  def encode_answer(:delete, :ok), do: %{}

  def encode_answer(:query, %Glider.Result{} = r) do
    %{
      "columns" => r.columns,
      "rows" => Enum.map(r.rows, &encode_value/1),
      "graph" => %{
        "nodes" => Enum.map(r.graph.nodes, &encode_value/1),
        "edges" => Enum.map(r.graph.edges, &encode_value/1)
      },
      "message" => r.message,
      "touched" => r.touched
    }
  end

  def encode_answer(:find, %Glider.Result{} = r),
    do: %{"columns" => r.columns, "rows" => Enum.map(r.rows, &encode_value/1)}

  def encode_answer(op, touched) when op in [:run, :write_batch] and is_integer(touched),
    do: %{"touched" => touched}

  def encode_answer(:context, %{text: text} = c) do
    %{
      "text" => text,
      "tokens" => c[:tokens],
      "nodes" => c[:nodes],
      "edges" => c[:edges],
      "refs" => c[:refs] || [],
      "message" => c[:message]
    }
  end

  def encode_answer(:schema, %{} = schema) do
    Map.new([:labels, :edge_types, :indexes], fn key ->
      {Atom.to_string(key),
       Enum.map(Map.get(schema, key, []), &%{"name" => &1.name, "count" => &1.count})}
    end)
  end

  def encode_answer(:stats, %{} = stats),
    do: Map.new(stats, fn {k, v} -> {to_string(k), encode_value(v)} end)

  def encode_answer(:search, hits) when is_list(hits) do
    Enum.map(hits, fn %{ref: ref, score: score, card: card} ->
      %{"ref" => ref, "score" => score, "card" => card_json(card)}
    end)
  end

  defp card_json(%Card{} = card), do: card |> Card.encode() |> JSON.decode!()

  @doc """
  Reads the answer to an op from its decoded JSON body, giving the terms the
  local call gives. Cards read are input (`Aerotow.Card.from_map/1`); `store`
  on them is `store`, the name of the peer store they came through.
  """
  @spec decode_answer(op(), term(), String.t() | nil) :: {:ok, term()} | {:error, String.t()}
  def decode_answer(op, body, store \\ nil) do
    answer(op, body, store)
  catch
    {:bad, message} -> {:error, "the peer's answer to #{name(op)}: #{message}"}
  end

  defp answer(:gliders, %{"gliders" => cards, "next" => next}, store)
       when is_list(cards) and (is_nil(next) or is_binary(next)) do
    {:ok, %{gliders: Enum.map(cards, &card!(&1, store)), next: next}}
  end

  defp answer(op, %{} = card, store) when op in [:card, :create, :update],
    do: {:ok, card!(card, store)}

  defp answer(:delete, %{}, _store), do: {:ok, :ok}

  defp answer(:query, %{"columns" => columns, "rows" => rows, "graph" => graph} = b, _store)
       when is_list(columns) and is_list(rows) and is_map(graph) do
    {:ok,
     %Glider.Result{
       columns: texts!(columns),
       rows: Enum.map(rows, &row!/1),
       graph: %{
         nodes: graph |> Map.get("nodes", []) |> list!() |> Enum.map(&value(&1, 0)),
         edges: graph |> Map.get("edges", []) |> list!() |> Enum.map(&value(&1, 0))
       },
       message: optional_text!(b["message"]),
       touched: natural!(Map.get(b, "touched", 0))
     }}
  end

  defp answer(:find, %{"columns" => columns, "rows" => rows}, _store)
       when is_list(columns) and is_list(rows),
       do: {:ok, %Glider.Result{columns: texts!(columns), rows: Enum.map(rows, &row!/1)}}

  defp answer(op, %{"touched" => touched}, _store) when op in [:run, :write_batch],
    do: {:ok, natural!(touched)}

  defp answer(:context, %{"text" => text} = b, _store) when is_binary(text) do
    {:ok,
     %{
       text: text,
       tokens: natural!(b["tokens"]),
       nodes: optional_natural!(b["nodes"]),
       edges: optional_natural!(b["edges"]),
       refs: texts!(list!(Map.get(b, "refs", []))),
       message: optional_text!(b["message"])
     }}
  end

  defp answer(:schema, %{} = b, _store) do
    {:ok,
     %{
       labels: counts!(Map.get(b, "labels", [])),
       edge_types: counts!(Map.get(b, "edge_types", [])),
       indexes: counts!(Map.get(b, "indexes", []))
     }}
  end

  defp answer(:stats, %{} = b, _store), do: {:ok, Map.new(b, fn {k, v} -> {k, value(v, 0)} end)}

  defp answer(:search, hits, store) when is_list(hits) do
    {:ok,
     Enum.map(hits, fn
       %{"ref" => ref, "score" => score, "card" => card}
       when is_binary(ref) and is_number(score) ->
         %{ref: ref, score: score, card: card!(card, store)}

       _ ->
         bad("a hit is {ref, score, card}")
     end)}
  end

  defp answer(_op, _body, _store), do: bad("it is not the shape of one")

  defp card!(%{} = map, store) do
    case Card.from_map(map) do
      {:ok, card} -> %{card | store: store, aloft: false}
      {:error, reason} -> bad("a card: " <> reason)
    end
  end

  defp card!(_, _store), do: bad("a card is an object")

  defp row!(row) when is_list(row), do: Enum.map(row, &value(&1, 0))
  defp row!(_), do: bad("a row is a list")

  defp list!(list) when is_list(list), do: list
  defp list!(_), do: bad("a list was expected")

  defp texts!(list) do
    if Enum.all?(list, &is_binary/1), do: list, else: bad("a list of text was expected")
  end

  defp natural!(n) when is_integer(n) and n >= 0, do: n
  defp natural!(_), do: bad("a whole number was expected")

  defp optional_natural!(nil), do: nil
  defp optional_natural!(n), do: natural!(n)

  defp optional_text!(nil), do: nil
  defp optional_text!(t) when is_binary(t), do: t
  defp optional_text!(_), do: bad("text was expected")

  defp counts!(list) when is_list(list) do
    Enum.map(list, fn
      %{"name" => name, "count" => count} when is_binary(name) and is_integer(count) ->
        %{name: name, count: count}

      _ ->
        bad("a schema entry is {name, count}")
    end)
  end

  defp counts!(_), do: bad("a schema's entries are a list")

  # ------------------------------------------------------------------ errors

  @doc """
  An error reason as an HTTP status and a body, `{"error", "code"}` and, for
  some codes, what the reason carries.

      iex> Aerotow.Wire.encode_error(:not_found)
      {404, %{"error" => "no store has a glider of that ref", "code" => "not_found"}}
  """
  @spec encode_error(term()) :: {pos_integer(), map()}
  def encode_error(:not_found), do: error(404, "not_found", "no store has a glider of that ref")
  def encode_error(:exists), do: error(409, "exists", "a glider of that ref exists")
  def encode_error(:purging), do: error(409, "purging", "the glider is being purged")
  def encode_error(:timeout), do: error(504, "timeout", "the call timed out")

  def encode_error(:too_many_hops),
    do: error(508, "too_many_hops", "the call was forwarded too many times")

  def encode_error(reason) when reason in @unavailable,
    do: error(503, "unavailable", Atom.to_string(reason), %{"reason" => Atom.to_string(reason)})

  def encode_error({:aloft_elsewhere, holder}) do
    error(409, "aloft_elsewhere", "the glider is aloft on another instance", %{
      "holder" => %{
        "holder" => holder.holder,
        "node" => holder.node,
        "url" => holder.url,
        "flight" => holder.flight
      }
    })
  end

  def encode_error({:runs_on_peer, store}),
    do: error(409, "runs_on_peer", "the glider runs on the peer #{store}", %{"store" => store})

  def encode_error({:store_unavailable, name, reason}),
    do: error(503, "store_unavailable", "store #{name}: #{reason}", %{"store" => name})

  def encode_error({kind, name, reason}) when kind in [:peer_unavailable, :outcome_unknown],
    do: error(503, Atom.to_string(kind), "peer #{name}: #{reason}", %{"store" => name})

  def encode_error(reason) when is_binary(reason), do: error(422, "refused", reason)
  def encode_error(reason), do: error(500, "error", inspect(reason, limit: 20))

  defp error(status, code, message, extra \\ %{}),
    do: {status, Map.merge(extra, %{"error" => message, "code" => code})}

  @doc """
  The reason an error body stands for, as `encode_error/1` wrote it. A body
  that is not an aerotow error is `:error`.
  """
  @spec decode_error(term()) :: {:ok, term()} | :error
  def decode_error(%{"code" => code, "error" => message} = body)
      when is_binary(code) and is_binary(message) do
    {:ok, reason(code, message, body)}
  end

  def decode_error(_), do: :error

  defp reason("not_found", _, _), do: :not_found
  defp reason("exists", _, _), do: :exists
  defp reason("purging", _, _), do: :purging
  defp reason("timeout", _, _), do: :timeout
  defp reason("too_many_hops", _, _), do: :too_many_hops

  defp reason("unavailable", message, body) do
    case Enum.find(@unavailable, &(Atom.to_string(&1) == body["reason"])) do
      nil -> message
      reason -> reason
    end
  end

  defp reason("aloft_elsewhere", message, %{"holder" => h}) when is_map(h) do
    with holder when is_binary(holder) <- h["holder"],
         node when is_nil(node) or is_binary(node) <- h["node"],
         url when is_nil(url) or is_binary(url) <- h["url"],
         flight when is_integer(flight) and flight > 0 <- h["flight"] do
      {:aloft_elsewhere, %{holder: holder, node: node, url: url, flight: flight}}
    else
      _ -> message
    end
  end

  defp reason("runs_on_peer", _, %{"store" => store}) when is_binary(store),
    do: {:runs_on_peer, store}

  defp reason("store_unavailable", message, %{"store" => store}) when is_binary(store),
    do: {:store_unavailable, store, message}

  defp reason(code, message, %{"store" => store})
       when code in ["peer_unavailable", "outcome_unknown"] and is_binary(store) do
    kind = if code == "peer_unavailable", do: :peer_unavailable, else: :outcome_unknown
    {kind, store, message}
  end

  defp reason(_code, message, _body), do: message
end
