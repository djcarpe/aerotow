defmodule Aerotow.Card do
  @moduledoc """
  A glider's metadata: what it is called, what it holds, where its newest
  shipped state is.

  A card is a JSON document beside its glider in the store
  (`cards/<ref>.json`, or `<ref>.card.json` in a file store) and a `:Glider`
  node in the catalog. Only the instance holding a glider's flight writes its
  card.

  The fields somebody sets:

    * `description` - a sentence or two, at most 4,096 bytes
    * `tags` - short lower-case words
    * `attrs` - the embedding application's own flat properties
      (`visibility`, `owner`). Names aerotow uses for itself are refused
    * `links` - refs of the gliders this one links to
    * `mode` - where its pages live when it is aloft: `"auto"`, `"memory"`
      or `"disk"`
    * `hot` - bytes of hot set to keep in memory, or `nil`

  The fields read from the glider (`observe/1`): `nodes`, `edges`, `bytes`,
  `labels`, `types`, `indexes`, `extensions`, `schema`.

  The fields a flight writes: `flight`, `generation`, `position` (where the
  newest shipped state was when the card was written; a hint, never trusted
  by a launch) and the three timestamps, unix seconds.

  `store` and `aloft` are not part of the stored card: they say where this
  instance found it and whether it is open here.

  A card read from a store or a peer is input. `decode/1` parses its refs,
  bounds its sizes, ignores fields it does not know and never makes an atom
  from anything in it.
  """

  alias Aerotow.Ref

  @format 1
  @max_card_bytes 1_048_576
  @max_description 4_096
  @max_schema 262_144
  @max_tags 64
  @max_attrs 64
  @max_links 1_024
  @max_counts 10_000
  @max_attr_string 4_096
  @modes ~w(auto memory disk)

  # Property names the catalog uses on a :Glider node. An attr may not take one.
  @reserved ~w(ref namespace name description tags links mode hot nodes edges bytes
               labels types indexes extensions schema text flight generation position
               aloft known store created_at updated_at described_at format attrs attr_names)

  @tag ~r/\A[a-z0-9](?:[a-z0-9._:-]{0,62})\z/
  @attr_key ~r/\A[a-z][a-z0-9_]{0,62}\z/

  @enforce_keys [:ref]
  defstruct ref: nil,
            description: nil,
            tags: [],
            attrs: %{},
            links: [],
            mode: "auto",
            hot: nil,
            nodes: 0,
            edges: 0,
            bytes: 0,
            labels: [],
            types: [],
            indexes: [],
            extensions: [],
            schema: nil,
            flight: nil,
            generation: nil,
            position: nil,
            created_at: nil,
            updated_at: nil,
            described_at: nil,
            store: nil,
            aloft: false

  @typedoc "A name with how many there are: a label, a relationship type, an index."
  @type count :: %{name: String.t(), count: non_neg_integer()}

  @typedoc "An attr's value: flat, as glider's own property values are."
  @type attr :: String.t() | integer() | float() | boolean() | [String.t()]

  @type t :: %__MODULE__{
          ref: Ref.t(),
          description: String.t() | nil,
          tags: [String.t()],
          attrs: %{String.t() => attr()},
          links: [Ref.t()],
          mode: String.t(),
          hot: non_neg_integer() | nil,
          nodes: non_neg_integer(),
          edges: non_neg_integer(),
          bytes: non_neg_integer(),
          labels: [count()],
          types: [count()],
          indexes: [count()],
          extensions: [String.t()],
          schema: String.t() | nil,
          flight: pos_integer() | nil,
          generation: String.t() | nil,
          position: non_neg_integer() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil,
          described_at: integer() | nil,
          store: String.t() | nil,
          aloft: boolean()
        }

  @typedoc "What `observe/1` reads from an open glider."
  @type observation :: %{
          nodes: non_neg_integer(),
          edges: non_neg_integer(),
          bytes: non_neg_integer(),
          labels: [count()],
          types: [count()],
          indexes: [count()],
          extensions: [String.t()],
          schema: String.t() | nil
        }

  @doc "The property names aerotow keeps for itself; an attr may not use one."
  @spec reserved() :: [String.t()]
  def reserved, do: @reserved

  @doc """
  A card for a new glider. `opts` are the fields somebody sets:
  `:description`, `:tags`, `:attrs`, `:links`, `:mode`, `:hot`.

      iex> {:ok, card} = Aerotow.Card.new("public/site", description: "What the product is", tags: ["docs"])
      iex> {card.ref, card.tags, card.mode}
      {"public/site", ["docs"], "auto"}
  """
  @spec new(term(), keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(ref, opts \\ []) do
    with {:ok, ref} <- Ref.parse(ref) do
      change(%__MODULE__{ref: ref}, opts)
    end
  end

  @doc """
  Applies somebody's changes to the fields they may set. Unknown keys are an
  error, so a typo is not silently dropped.
  """
  @spec change(t(), keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def change(%__MODULE__{} = card, changes) do
    if pairs?(changes) do
      Enum.reduce_while(changes, {:ok, card}, fn {key, value}, {:ok, card} ->
        case put(card, to_string(key), value) do
          {:ok, card} -> {:cont, {:ok, card}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, "changes to a card are a map or a keyword list"}
    end
  end

  defp pairs?(term), do: is_map(term) or Keyword.keyword?(term)

  defp put(card, "description", nil), do: {:ok, %{card | description: nil}}

  defp put(card, "description", d) when is_binary(d) do
    cond do
      not String.valid?(d) ->
        {:error, "description is not valid UTF-8"}

      byte_size(d) > @max_description ->
        {:error, "description is longer than #{@max_description} bytes"}

      true ->
        {:ok, %{card | description: d}}
    end
  end

  defp put(card, "tags", tags) when is_list(tags) do
    cond do
      length(tags) > @max_tags ->
        {:error, "more than #{@max_tags} tags"}

      bad = Enum.find(tags, &(not (is_binary(&1) and Regex.match?(@tag, &1)))) ->
        {:error, "not a tag: #{inspect(bad)} (lower-case letters, digits, '.', '_', ':' or '-')"}

      true ->
        {:ok, %{card | tags: tags |> Enum.uniq() |> Enum.sort()}}
    end
  end

  defp put(_card, "attrs", attrs) when not is_map(attrs) and not is_list(attrs),
    do: {:error, "attrs has the wrong shape: #{inspect(attrs, limit: 5)}"}

  defp put(card, "attrs", attrs) do
    if pairs?(attrs),
      do: put_attrs(card, attrs),
      else: {:error, "attrs is a map of names to flat values"}
  end

  defp put(card, "links", links) when is_list(links) do
    if length(links) > @max_links do
      {:error, "more than #{@max_links} links"}
    else
      links
      |> Enum.reduce_while({:ok, []}, fn link, {:ok, acc} ->
        case Ref.parse(link) do
          {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
          {:error, reason} -> {:halt, {:error, "link: " <> reason}}
        end
      end)
      |> case do
        {:ok, refs} -> {:ok, %{card | links: refs |> Enum.uniq() |> Enum.sort()}}
        error -> error
      end
    end
  end

  defp put(card, "mode", mode) when is_atom(mode) and not is_nil(mode),
    do: put(card, "mode", Atom.to_string(mode))

  defp put(card, "mode", mode) when mode in @modes, do: {:ok, %{card | mode: mode}}

  defp put(_card, "mode", mode),
    do: {:error, "mode is \"auto\", \"memory\" or \"disk\", got: #{inspect(mode)}"}

  defp put(card, "hot", nil), do: {:ok, %{card | hot: nil}}
  defp put(card, "hot", n) when is_integer(n) and n >= 0, do: {:ok, %{card | hot: n}}

  defp put(_card, "hot", other),
    do: {:error, "hot is a number of bytes or nil, got: #{inspect(other)}"}

  defp put(_card, key, value) when key in ~w(description tags links),
    do: {:error, "#{key} has the wrong shape: #{inspect(value, limit: 5)}"}

  defp put(_card, key, _value),
    do: {:error, "#{inspect(key)} is not a field somebody sets on a card"}

  defp put_attrs(card, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    cond do
      map_size(attrs) > @max_attrs ->
        {:error, "more than #{@max_attrs} attrs"}

      bad = Enum.find(Map.keys(attrs), &(not Regex.match?(@attr_key, &1))) ->
        {:error,
         "not an attr name: #{inspect(bad)} (a lower-case letter, then letters, digits or '_')"}

      taken = Enum.find(Map.keys(attrs), &(&1 in @reserved)) ->
        {:error, "attr #{inspect(taken)} is a name aerotow uses on the card"}

      bad = Enum.find(attrs, fn {_, v} -> not attr_value?(v) end) ->
        {k, v} = bad
        {:error, "attr #{inspect(k)} has a value that is not flat: #{inspect(v, limit: 5)}"}

      true ->
        {:ok, %{card | attrs: attrs}}
    end
  end

  defp attr_value?(v) when is_binary(v), do: String.valid?(v) and byte_size(v) <= @max_attr_string
  defp attr_value?(v) when is_integer(v) or is_float(v) or is_boolean(v), do: true

  defp attr_value?(v) when is_list(v),
    do: length(v) <= 256 and Enum.all?(v, &(is_binary(&1) and attr_value?(&1)))

  defp attr_value?(_), do: false

  # ------------------------------------------------------------------ the glider

  @doc """
  Reads what a card says about a glider's contents from the open glider:
  counts, labels, relationship types, indexes, installed extensions, and the
  `context` extension's schema card when that extension is installed.
  """
  @spec observe(Glider.db()) :: {:ok, observation()} | {:error, String.t()}
  def observe(db) do
    with {:ok, stats} <- Glider.stats(db),
         {:ok, schema} <- Glider.schema(db),
         {:ok, extensions} <- Glider.extensions(db) do
      installed = for %{name: name, installed: version} <- extensions, version != nil, do: name

      {:ok,
       %{
         nodes: count(stats["nodes"]),
         edges: count(stats["edges"]),
         bytes: count(stats["file_bytes"]),
         labels: counts(schema.labels),
         types: counts(schema.edge_types),
         indexes: counts(schema.indexes),
         extensions: Enum.sort(installed),
         schema: schema_card(db, installed)
       }}
    end
  end

  @doc "A card with an observation put on it, `described_at` and `updated_at` set to `now` (unix seconds)."
  @spec put_observation(t(), observation(), integer()) :: t()
  def put_observation(%__MODULE__{} = card, obs, now) do
    card
    |> struct!(Map.take(obs, ~w(nodes edges bytes labels types indexes extensions schema)a))
    |> Map.merge(%{described_at: now, updated_at: now})
  end

  defp schema_card(db, installed) do
    if "context" in installed do
      case Glider.Context.schema(db) do
        {:ok, text} when byte_size(text) <= @max_schema -> text
        _ -> nil
      end
    end
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: 0

  defp counts(entries) do
    entries
    |> Enum.map(fn e -> %{name: to_string(e.name), count: count(e.count)} end)
    |> Enum.sort_by(& &1.name)
  end

  # ------------------------------------------------------------------ search

  @doc """
  The words full-text search finds a glider by: its ref, labels,
  relationship types and tags.

      iex> {:ok, card} = Aerotow.Card.new("public/site", tags: ["docs"])
      iex> Aerotow.Card.text(%{card | labels: [%{name: "Section", count: 3}]})
      "public/site public site Section docs"
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = card) do
    names = fn counts -> Enum.map(counts, & &1.name) end

    [card.ref | Ref.segments(card.ref)]
    |> Enum.concat(names.(card.labels))
    |> Enum.concat(names.(card.types))
    |> Enum.concat(card.tags)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  # ------------------------------------------------------------------ JSON

  @doc """
  The card as JSON: one field a line, always in the same order, so the same
  card is the same bytes.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = card) do
    fields = [
      {"format", @format},
      {"ref", card.ref},
      {"description", card.description},
      {"tags", card.tags},
      {"attrs", {:object, card.attrs |> Enum.sort() |> Enum.map(fn {k, v} -> {k, v} end)}},
      {"links", card.links},
      {"mode", card.mode},
      {"hot", card.hot},
      {"nodes", card.nodes},
      {"edges", card.edges},
      {"bytes", card.bytes},
      {"labels", {:counts, card.labels}},
      {"types", {:counts, card.types}},
      {"indexes", {:counts, card.indexes}},
      {"extensions", card.extensions},
      {"schema", card.schema},
      {"flight", card.flight},
      {"generation", card.generation},
      {"position", card.position},
      {"created_at", card.created_at},
      {"updated_at", card.updated_at},
      {"described_at", card.described_at}
    ]

    body = Enum.map_join(fields, ",\n  ", fn {k, v} -> [json(k), ": ", value(v)] end)
    IO.iodata_to_binary(["{\n  ", body, "\n}\n"])
  end

  defp value({:object, pairs}),
    do: ["{", Enum.map_join(pairs, ", ", fn {k, v} -> [json(k), ": ", json(v)] end), "}"]

  defp value({:counts, counts}),
    do: [
      "[",
      Enum.map_join(counts, ", ", fn c ->
        ["{\"name\": ", json(c.name), ", \"count\": ", json(c.count), "}"]
      end),
      "]"
    ]

  defp value(v), do: json(v)

  defp json(v), do: v |> JSON.encode!() |> IO.iodata_to_binary()

  @doc """
  Reads a card from JSON that came from a store or a peer. Everything in it
  is checked; fields this version does not know are ignored.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    if byte_size(json) > @max_card_bytes do
      {:error, "a card of #{byte_size(json)} bytes is too large"}
    else
      case JSON.decode(json) do
        {:ok, %{} = map} -> from_map(map)
        {:ok, _} -> {:error, "a card is a JSON object"}
        {:error, _} -> {:error, "a card is JSON, and this is not"}
      end
    end
  end

  @doc "Reads a card from a decoded JSON object (string keys), checking it as `decode/1` does."
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(%{} = map) do
    with :ok <- format(map["format"]),
         {:ok, card} <-
           new(map["ref"],
             description: map["description"],
             tags: map["tags"] || [],
             attrs: map["attrs"] || %{},
             links: map["links"] || [],
             mode: map["mode"] || "auto",
             hot: map["hot"]
           ),
         {:ok, labels} <- counts_in(map["labels"], "labels"),
         {:ok, types} <- counts_in(map["types"], "types"),
         {:ok, indexes} <- counts_in(map["indexes"], "indexes"),
         {:ok, extensions} <- strings_in(map["extensions"], "extensions"),
         {:ok, schema} <- text_in(map["schema"], "schema", @max_schema),
         {:ok, generation} <- text_in(map["generation"], "generation", 64) do
      {:ok,
       %{
         card
         | nodes: natural(map["nodes"]) || 0,
           edges: natural(map["edges"]) || 0,
           bytes: natural(map["bytes"]) || 0,
           labels: labels,
           types: types,
           indexes: indexes,
           extensions: extensions,
           schema: schema,
           flight: positive(map["flight"]),
           generation: generation,
           position: natural(map["position"]),
           created_at: natural(map["created_at"]),
           updated_at: natural(map["updated_at"]),
           described_at: natural(map["described_at"])
       }}
    end
  end

  defp format(@format), do: :ok

  defp format(other),
    do: {:error, "a card of format #{inspect(other)}; this aerotow reads format #{@format}"}

  defp counts_in(nil, _), do: {:ok, []}

  defp counts_in(list, what) when is_list(list) and length(list) <= @max_counts do
    list
    |> Enum.reduce_while({:ok, []}, fn
      %{"name" => name, "count" => count}, {:ok, acc}
      when is_binary(name) and byte_size(name) <= 1_024 and is_integer(count) and count >= 0 ->
        {:cont, {:ok, [%{name: name, count: count} | acc]}}

      _, _ ->
        {:halt, {:error, "#{what} is a list of {name, count}"}}
    end)
    |> case do
      {:ok, counts} -> {:ok, Enum.sort_by(counts, & &1.name)}
      error -> error
    end
  end

  defp counts_in(_, what), do: {:error, "#{what} is a list of {name, count}"}

  defp strings_in(nil, _), do: {:ok, []}

  defp strings_in(list, what) when is_list(list) and length(list) <= 256 do
    if Enum.all?(list, &(is_binary(&1) and byte_size(&1) <= 256)),
      do: {:ok, Enum.sort(list)},
      else: {:error, "#{what} is a list of names"}
  end

  defp strings_in(_, what), do: {:error, "#{what} is a list of names"}

  defp text_in(nil, _, _), do: {:ok, nil}

  defp text_in(text, what, max) when is_binary(text) do
    if byte_size(text) <= max,
      do: {:ok, text},
      else: {:error, "#{what} is longer than #{max} bytes"}
  end

  defp text_in(_, what, _), do: {:error, "#{what} is text"}

  defp natural(n) when is_integer(n) and n >= 0, do: n
  defp natural(_), do: nil

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil
end
