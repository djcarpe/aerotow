defmodule Aerotow.Store do
  @moduledoc """
  A place gliders are kept.

  | kind | url | what is there |
  |---|---|---|
  | `:file` | a directory, with `kind: :file` | live databases, `<root>/<ref>.gldb`, opened where they lie |
  | `:dir` | a directory | replicas, in the layout of `Aerotow.Store.Layout` |
  | `:s3` | `s3://bucket/prefix` | the same, in a bucket |
  | `:peer` | `http://` or `https://` | another aerotow, which answers for its own gliders |

  `new/3` makes one. The kind's module (`Aerotow.Store.Dir`,
  `Aerotow.Store.File`, `Aerotow.Store.S3`, `Aerotow.Store.Peer`) checks the
  url and options. An object store is then probed, which says whether an
  exclusive put really is exclusive there (`cas`), and its marker,
  `aerotow.json`, is read or created; the marker's id is the store's `id`.

  ## Objects

  `:dir` and `:s3` stores hold objects (`Aerotow.Store.Objects`): `get/2`,
  `put/4`, `delete/2`, `list/3` and `replica/2` check the key and call the
  store's module. Any other kind answers `{:error, :not_objects}`. A key is
  checked by `check_key/1` whatever store it is for, so a key that could
  leave a store's root never reaches its module.

  ## Cards

  `read_card/2`, `write_card/2`, `delete_card/2`, `list_cards/1` and
  `purge/2` work on every kind that keeps cards. An object store keeps a card
  as the object `Aerotow.Store.Layout.card/1` names; a kind that is not an
  object store keeps them its own way, in functions of the same names that
  take the store (`Aerotow.Store.File`).

  A card read from a store is input (R6): it is decoded by
  `Aerotow.Card.decode/1`, and one whose `ref` is not the ref it was read as
  is refused, so a card copied to the wrong name is not believed.

  ## Credentials

  `config` belongs to the module in `mod` and may hold credentials. `public/1`
  is what may be shown, logged, written to the catalog or sent to a peer.
  `inspect/1` leaves `config` out, and `url` holds no credentials: `new/3`
  keeps any `user:password@` out of it and gives the whole url only to the
  kind's module (R4).
  """

  alias Aerotow.{Card, Clock, Ref}
  alias Aerotow.Store.Layout

  @derive {Inspect, except: [:config]}
  @enforce_keys [:name, :kind, :url, :mod]
  defstruct name: nil,
            kind: nil,
            url: nil,
            mod: nil,
            config: %{},
            cas: nil,
            single_writer: false,
            mode: nil,
            hot: nil,
            id: nil

  @type kind :: :file | :dir | :s3 | :peer

  @typedoc "An object's key: relative to the store's root, segments separated by `/`."
  @type key :: String.t()

  @type listing :: %{objects: [Aerotow.Store.Objects.object()], prefixes: [String.t()]}

  @typedoc """
  What `probe_cas/2` tries a store with: its own `put`, `get` and `delete`,
  as functions of a key.
  """
  @type ops :: %{
          put: (key(), iodata(), keyword() -> :ok | {:error, term()}),
          get: (key() -> {:ok, binary()} | {:error, term()}),
          delete: (key() -> :ok | {:error, term()})
        }

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          url: String.t(),
          mod: module(),
          config: map(),
          cas: boolean() | nil,
          single_writer: boolean(),
          mode: String.t() | nil,
          hot: non_neg_integer() | nil,
          id: String.t() | nil
        }

  @modules %{
    dir: Aerotow.Store.Dir,
    file: Aerotow.Store.File,
    s3: Aerotow.Store.S3,
    peer: Aerotow.Store.Peer
  }

  @name ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/
  @scheme ~r/\A[A-Za-z][A-Za-z0-9+.-]*:\/\//
  @id ~r/\A[0-9a-f]{32}\z/
  @control ~r/[\x00-\x1F\x7F]/
  @max_key 1_024
  @max_segment 255
  @max_marker 65_536
  @marker_tries 3
  @probe_rounds 2
  @probe_racers 8
  @probe_timeout 30_000

  # ------------------------------------------------------------------ new

  @doc """
  Makes the store `name` from its url.

  The kind comes from the url: `s3://…` is `:s3`, `http://` or `https://` is
  `:peer`, and anything else is a directory, which is `:dir` unless
  `kind: :file` is given. A directory may be written with a `file://` prefix;
  a relative one is expanded, and one that does not exist is created. A
  `kind:` that contradicts the url is an error, and so is a url whose scheme
  is none of those.

  An object store is then probed and its marker read, or created with an
  exclusive put when there is none: two stores made at once on an empty
  directory or bucket agree on one id. A marker of another format, or one
  that is not a marker, is refused. A store whose exclusive puts are not
  exclusive is still returned, with `cas: false`: it can be read, and the
  flight layer refuses to write there unless it is `single_writer`.

  Options: `kind:`, `single_writer:` (default `false`: the promise that no
  second instance writes to this store), `clock:` (an `Aerotow.Clock`, for
  the marker's `created_at`), `mode:` and `hot:` (where the gliders kept
  here hold their pages when aloft, over what their cards say; see
  `Aerotow.Flight.Copy.decide/3`), and whatever the kind's module takes
  (`endpoint:`, `token:`, …).
  """
  @spec new(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(name, url, opts \\ [])

  def new(name, url, opts) when is_binary(url) and is_list(opts) do
    with :ok <- check_options(opts),
         :ok <- check_name(name),
         {:ok, kind, location} <- kind(url, Keyword.get(opts, :kind)),
         {:ok, single_writer} <- single_writer(opts),
         {:ok, mode} <- Aerotow.Options.mode(Keyword.get(opts, :mode)),
         {:ok, hot} <- Aerotow.Options.hot(Keyword.get(opts, :hot)),
         {:ok, clock} <- clock(opts),
         {:ok, mod} <- module(kind),
         {:ok, config} <- init(mod, name, location, opts) do
      store = %__MODULE__{
        name: name,
        kind: kind,
        url: shown(kind, location),
        mod: mod,
        config: config,
        single_writer: single_writer,
        mode: mode,
        hot: hot
      }

      if objects?(store), do: open(store, clock), else: {:ok, store}
    end
  end

  # Neither a url that is not a string nor the options are repeated in the
  # reason: either may hold a credential.
  def new(_name, url, _opts) when is_binary(url),
    do: {:error, "a store's options are a keyword list"}

  def new(_name, _url, _opts), do: {:error, "a store's url is a string"}

  defp check_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, "a store's options are a keyword list"}
  end

  defp check_name(name) when is_binary(name) do
    if Regex.match?(@name, name),
      do: :ok,
      else:
        {:error,
         "not a store name: #{inspect(name)} (lower-case letters, digits, '_' or '-', " <>
           "starting with a letter or digit, at most 63 bytes)"}
  end

  defp check_name(other), do: {:error, "a store's name is a string, got: #{inspect(other)}"}

  defp kind(url, given) do
    with {:ok, found, location} <- detect(url) do
      case {found, given} do
        {:path, nil} -> {:ok, :dir, location}
        {:path, kind} when kind in [:dir, :file] -> {:ok, kind, location}
        {kind, nil} -> {:ok, kind, location}
        {kind, kind} when kind in [:s3, :peer] -> {:ok, kind, location}
        {_, kind} when kind in [:dir, :file, :s3, :peer] -> contradiction(found, kind, location)
        {_, other} -> {:error, "kind is :dir, :file, :s3 or :peer, got: #{inspect(other)}"}
      end
    end
  end

  defp contradiction(found, kind, location) do
    url = if found == :path, do: location, else: strip_userinfo(location)
    {:error, "kind: #{inspect(kind)} does not match #{url}, which is #{what(found)}"}
  end

  defp what(:path), do: "a directory"
  defp what(:s3), do: "a bucket"
  defp what(:peer), do: "another aerotow"

  defp detect(url) do
    cond do
      not String.valid?(url) or String.contains?(url, <<0>>) ->
        {:error, "a store's url is UTF-8 text with no NUL in it"}

      String.starts_with?(url, "s3://") ->
        {:ok, :s3, url}

      String.starts_with?(url, ["http://", "https://"]) ->
        {:ok, :peer, url}

      String.starts_with?(url, "file://") ->
        directory(binary_part(url, 7, byte_size(url) - 7))

      Regex.match?(@scheme, url) ->
        {:error,
         "#{strip_userinfo(url)} has a scheme aerotow does not know: a store is " <>
           "s3://, http://, https://, file:// or a directory"}

      true ->
        directory(url)
    end
  end

  defp directory(""), do: {:error, "a store's url is empty"}
  defp directory(path), do: {:ok, :path, Path.expand(path)}

  defp shown(kind, location) when kind in [:dir, :file], do: location
  defp shown(_kind, location), do: strip_userinfo(location)

  defp single_writer(opts) do
    case Keyword.get(opts, :single_writer, false) do
      flag when is_boolean(flag) -> {:ok, flag}
      other -> {:error, "single_writer is true or false, got: #{inspect(other)}"}
    end
  end

  defp clock(opts) do
    case Keyword.get(opts, :clock, :system) do
      :system -> {:ok, :system}
      clock when is_function(clock, 0) -> {:ok, clock}
      other -> {:error, "clock is :system or a function of no arguments, got: #{inspect(other)}"}
    end
  end

  defp module(kind) do
    mod = Map.fetch!(@modules, kind)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :init, 3),
      do: {:ok, mod},
      else: {:error, "the #{kind} kind of store is not available in this build"}
  end

  defp init(mod, name, location, opts) do
    case mod.init(name, location, opts) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:error, reason} -> {:error, "store #{inspect(name)}: #{text(reason)}"}
      _ -> {:error, "store #{inspect(name)}: #{inspect(mod)}.init/3 did not answer {:ok, config}"}
    end
  end

  # An object store: find out what it can do, then read its marker.
  defp open(store, clock) do
    with {:ok, cas} <- probe(store),
         {:ok, id} <- marker(%{store | cas: cas}, clock, @marker_tries) do
      {:ok, %{store | cas: cas, id: id}}
    end
  end

  defp probe(store) do
    case store.mod.probe(store.config) do
      {:ok, %{cas: cas}} when is_boolean(cas) ->
        {:ok, cas}

      {:error, reason} ->
        {:error, "store #{inspect(store.name)} could not be probed: #{text(reason)}"}

      _ ->
        {:error, "store #{inspect(store.name)}: probe/1 did not answer {:ok, %{cas: boolean}}"}
    end
  end

  defp marker(store, _clock, 0),
    do: {:error, "store #{inspect(store.name)}: #{Layout.marker()} was there and then was not"}

  defp marker(store, clock, tries) do
    case store.mod.get(store.config, Layout.marker()) do
      {:ok, body} ->
        read_marker(store, body)

      {:error, :not_found} ->
        create_marker(store, clock, tries)

      {:error, reason} ->
        {:error, "store #{inspect(store.name)}: reading #{Layout.marker()}: #{text(reason)}"}
    end
  end

  # Exclusive where the store can do it, so that of two stores made at once
  # on one empty place, one writes the marker and the other reads it.
  defp create_marker(store, clock, tries) do
    id = random_id()
    body = encode_marker(id, Clock.seconds(clock))

    case store.mod.put(store.config, Layout.marker(), body, exclusive: store.cas) do
      :ok ->
        {:ok, id}

      {:error, :exists} ->
        marker(store, clock, tries - 1)

      {:error, reason} ->
        {:error, "store #{inspect(store.name)}: writing #{Layout.marker()}: #{text(reason)}"}
    end
  end

  defp encode_marker(id, created_at) do
    IO.iodata_to_binary([
      "{\n  \"format\": ",
      Integer.to_string(Layout.format()),
      ",\n  \"id\": ",
      JSON.encode!(id),
      ",\n  \"created_at\": ",
      Integer.to_string(created_at),
      "\n}\n"
    ])
  end

  defp read_marker(store, body) when byte_size(body) > @max_marker,
    do: {:error, not_marker(store, "it is #{byte_size(body)} bytes")}

  defp read_marker(store, body) do
    format = Layout.format()

    case JSON.decode(body) do
      {:ok, %{"format" => ^format, "id" => id, "created_at" => at}}
      when is_binary(id) and is_integer(at) and at >= 0 ->
        if Regex.match?(@id, id),
          do: {:ok, id},
          else: {:error, not_marker(store, "its id is not 32 hex digits")}

      {:ok, %{"format" => other}} when is_integer(other) and other != format ->
        {:error,
         "store #{inspect(store.name)} at #{store.url} is format #{other}; " <>
           "this aerotow reads format #{format}"}

      {:ok, %{}} ->
        {:error, not_marker(store, "it has no format, id and created_at")}

      _ ->
        {:error, not_marker(store, "it is not a JSON object")}
    end
  end

  defp not_marker(store, why),
    do:
      "store #{inspect(store.name)} at #{store.url}: #{Layout.marker()} is not a store's marker (#{why})"

  # ------------------------------------------------------------------ what is shown

  @doc """
  The store without anything secret: its name, kind, url and whether
  exclusive writes hold there. Any `user:password@` in the url is removed.
  """
  @spec public(t()) :: %{name: String.t(), kind: kind(), url: String.t(), cas: boolean() | nil}
  def public(%__MODULE__{} = store) do
    %{name: store.name, kind: store.kind, url: strip_userinfo(store.url), cas: store.cas}
  end

  @doc "Whether the store holds replicas as objects (`:dir`, `:s3`), and so has flights."
  @spec objects?(t()) :: boolean()
  def objects?(%__MODULE__{kind: kind}), do: kind in [:dir, :s3]

  defp strip_userinfo(url) do
    case URI.parse(url) do
      %URI{userinfo: info} = uri when is_binary(info) -> URI.to_string(%{uri | userinfo: nil})
      _ -> url
    end
  end

  # ------------------------------------------------------------------ objects

  @doc "The whole object at `key`, or `{:error, :not_found}`."
  @spec get(t(), key()) :: {:ok, binary()} | {:error, :not_found | :not_objects | term()}
  def get(%__MODULE__{} = store, key) do
    with :ok <- objects(store),
         :ok <- check_key(key),
         do: store.mod.get(store.config, key)
  end

  @doc """
  Writes the object at `key`. A reader never sees half of one, and a plain
  put replaces what is there.

  With `exclusive: true` the object is written only if nothing is there: of
  several writers racing for one key, exactly one gets `:ok` and the rest
  `{:error, :exists}`.
  """
  @spec put(t(), key(), iodata(), keyword()) :: :ok | {:error, :exists | :not_objects | term()}
  def put(%__MODULE__{} = store, key, body, opts \\ []) do
    with :ok <- objects(store),
         :ok <- check_key(key),
         :ok <- check_body(body),
         :ok <- check_flag(opts, :exclusive),
         do: store.mod.put(store.config, key, body, opts)
  end

  @doc "Deletes the object at `key`. Deleting one that is not there is `:ok`."
  @spec delete(t(), key()) :: :ok | {:error, :not_objects | term()}
  def delete(%__MODULE__{} = store, key) do
    with :ok <- objects(store),
         :ok <- check_key(key),
         do: store.mod.delete(store.config, key)
  end

  @doc """
  The objects whose keys start with `prefix`, in key order: `""` is every
  object. A prefix that matches nothing is an empty listing.

  With `delimiter: true`, only what is directly under `prefix`: the objects
  with no further `/` in the rest of their key, and in `prefixes` the
  "directories" (each ending in `/`) that hold everything else. Listing
  `Aerotow.Store.Layout.flights_prefix/1` that way gives a glider's flight
  records and their directories, and nothing inside them.
  """
  @spec list(t(), String.t(), keyword()) :: {:ok, listing()} | {:error, :not_objects | term()}
  def list(%__MODULE__{} = store, prefix, opts \\ []) do
    with :ok <- objects(store),
         :ok <- check_prefix(prefix),
         :ok <- check_flag(opts, :delimiter),
         do: store.mod.list(store.config, prefix, opts)
  end

  @doc """
  The replica url and options `Glider.Replication.sync/3` and `restore/3`
  take for everything under `prefix`, a key with no trailing slash
  (`Aerotow.Store.Layout.flight_data/2`).
  """
  @spec replica(t(), String.t()) ::
          {url :: String.t(), opts :: keyword()} | {:error, :not_objects | String.t()}
  def replica(%__MODULE__{} = store, prefix) do
    with :ok <- objects(store),
         :ok <- check_key(prefix),
         do: store.mod.replica(store.config, prefix)
  end

  defp objects(store), do: if(objects?(store), do: :ok, else: {:error, :not_objects})

  defp check_body(body) when is_binary(body) or is_list(body), do: :ok
  defp check_body(_), do: {:error, "an object's body is iodata"}

  defp check_flag(opts, name) do
    cond do
      not Keyword.keyword?(opts) -> {:error, "options are a keyword list"}
      is_boolean(Keyword.get(opts, name, false)) -> :ok
      true -> {:error, "#{name} is true or false, got: #{inspect(Keyword.get(opts, name))}"}
    end
  end

  @doc """
  Checks a key: relative, with segments separated by `/` of which none is
  empty, `.` or `..`, with no backslash and no control character, valid
  UTF-8, at most 1,024 bytes, and no segment over 255 bytes. Every object
  store refuses what this refuses, so no key can name anything outside a
  store's root.

      iex> Aerotow.Store.check_key("cards/engineering/code.json")
      :ok

      iex> Aerotow.Store.check_key("cards/../aerotow.json")
      {:error, "not a key: \\"cards/../aerotow.json\\" has a \\"..\\" segment"}
  """
  @spec check_key(term()) :: :ok | {:error, String.t()}
  def check_key(key), do: check(key, "key", false)

  @doc """
  Checks a prefix to list under: `""` (everything), or what `check_key/1`
  takes, with or without a `/` at the end.

      iex> Aerotow.Store.check_prefix("gliders/engineering/code/_flights/")
      :ok

      iex> Aerotow.Store.check_prefix("/etc/")
      {:error, "not a prefix: \\"/etc/\\" starts with /"}
  """
  @spec check_prefix(term()) :: :ok | {:error, String.t()}
  def check_prefix(""), do: :ok
  def check_prefix(prefix), do: check(prefix, "prefix", true)

  defp check(s, what, open?) when is_binary(s) do
    cond do
      s == "" ->
        {:error, "not a #{what}: it is empty"}

      byte_size(s) > @max_key ->
        {:error, "not a #{what}: longer than #{@max_key} bytes"}

      not String.valid?(s) ->
        {:error, "not a #{what}: #{inspect(s)} is not UTF-8"}

      String.starts_with?(s, "/") ->
        {:error, "not a #{what}: #{inspect(s)} starts with /"}

      String.contains?(s, "\\") ->
        {:error, "not a #{what}: #{inspect(s)} has a backslash"}

      Regex.match?(@control, s) ->
        {:error, "not a #{what}: #{inspect(s)} has a control character"}

      bad = Enum.find(segments(s, open?), &bad_segment?/1) ->
        {:error, "not a #{what}: #{inspect(s)} #{why(bad)}"}

      true ->
        :ok
    end
  end

  defp check(other, what, _open?),
    do: {:error, "not a #{what}: expected a string, got #{inspect(other)}"}

  # A prefix may end in `/`, which leaves one empty segment at the end.
  defp segments(s, open?) do
    segments = :binary.split(s, "/", [:global])

    if open? and String.ends_with?(s, "/"),
      do: Enum.drop(segments, -1),
      else: segments
  end

  defp bad_segment?(segment),
    do: segment in ["", ".", ".."] or byte_size(segment) > @max_segment

  defp why(""), do: "has an empty segment"
  defp why(dots) when dots in [".", ".."], do: "has a #{inspect(dots)} segment"
  defp why(_long), do: "has a segment longer than #{@max_segment} bytes"

  # ------------------------------------------------------------------ cards

  @doc """
  A glider's card, as this store has it, with `store:` set to the store's
  name. `{:error, :not_found}` when there is none.

  The card is input: what is not a card, and a card whose `ref` is not
  `ref`, is `{:error, reason}`.
  """
  @spec read_card(t(), Ref.t()) :: {:ok, Card.t()} | {:error, :not_found | String.t()}
  def read_card(%__MODULE__{} = store, ref) do
    with {:ok, ref} <- Ref.parse(ref),
         {:ok, card} <- fetch_card(store, ref) do
      if card.ref == ref,
        do: {:ok, %{card | store: store.name, aloft: false}},
        else: {:error, "the card read as #{inspect(ref)} names #{inspect(card.ref)}"}
    end
  end

  defp fetch_card(store, ref) do
    if objects?(store) do
      key = Layout.card(ref)

      case store.mod.get(store.config, key) do
        {:ok, json} -> decode_card(json, key)
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, "reading #{key}: #{text(reason)}"}
      end
    else
      kind_call(store, :read_card, [store, ref])
    end
  end

  defp decode_card(json, key) do
    case Card.decode(json) do
      {:ok, card} -> {:ok, card}
      {:error, reason} -> {:error, "#{key}: #{reason}"}
    end
  end

  @doc "Writes a glider's card, replacing the one there."
  @spec write_card(t(), Card.t()) :: :ok | {:error, String.t()}
  def write_card(%__MODULE__{} = store, %Card{} = card) do
    with {:ok, ref} <- Ref.parse(card.ref) do
      if objects?(store) do
        key = Layout.card(ref)

        case store.mod.put(store.config, key, Card.encode(card), []) do
          :ok -> :ok
          {:error, reason} -> {:error, "writing #{key}: #{text(reason)}"}
        end
      else
        kind_call(store, :write_card, [store, card])
      end
    end
  end

  def write_card(%__MODULE__{}, other), do: {:error, "not a card: #{inspect(other, limit: 5)}"}

  @doc "Deletes a glider's card. Deleting one that is not there is `:ok`."
  @spec delete_card(t(), Ref.t()) :: :ok | {:error, String.t()}
  def delete_card(%__MODULE__{} = store, ref) do
    with {:ok, ref} <- Ref.parse(ref) do
      if objects?(store),
        do: delete_object(store, Layout.card(ref)),
        else: kind_call(store, :delete_card, [store, ref])
    end
  end

  @doc """
  Every card in the store: its ref and a version that changes when the
  card's bytes do. Only the listing is read, not the cards; keys that are not
  a card's are skipped.
  """
  @spec list_cards(t()) :: {:ok, [%{ref: Ref.t(), version: String.t()}]} | {:error, String.t()}
  def list_cards(%__MODULE__{} = store) do
    if objects?(store) do
      case store.mod.list(store.config, Layout.cards_prefix(), []) do
        {:ok, %{objects: objects}} ->
          cards =
            for %{key: key, version: version} <- objects,
                {:ok, ref} <- [Layout.ref_of_card(key)],
                do: %{ref: ref, version: version}

          {:ok, Enum.sort_by(cards, & &1.ref)}

        {:error, reason} ->
          {:error, "listing #{Layout.cards_prefix()}: #{text(reason)}"}
      end
    else
      kind_call(store, :list_cards, [store])
    end
  end

  @doc """
  Deletes a glider from the store: its card, then its data. In an object
  store the data is everything under `Aerotow.Store.Layout.flights_prefix/1`
  and nothing else, so purging `a` leaves the glider `a/b` whole.

  Nothing may have the glider open while it is purged. A purge that fails
  part way says so and can be run again.
  """
  @spec purge(t(), Ref.t()) :: :ok | {:error, String.t()}
  def purge(%__MODULE__{} = store, ref) do
    with {:ok, ref} <- Ref.parse(ref) do
      if objects?(store),
        do: purge_objects(store, ref),
        else: kind_call(store, :purge, [store, ref])
    end
  end

  defp purge_objects(store, ref) do
    prefix = Layout.flights_prefix(ref)

    with :ok <- delete_object(store, Layout.card(ref)) do
      case store.mod.list(store.config, prefix, []) do
        {:ok, %{objects: objects}} ->
          Enum.reduce_while(objects, :ok, fn %{key: key}, :ok ->
            case delete_object(store, key) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)

        {:error, reason} ->
          {:error, "listing #{prefix}: #{text(reason)}"}
      end
    end
  end

  defp delete_object(store, key) do
    case store.mod.delete(store.config, key) do
      :ok -> :ok
      {:error, reason} -> {:error, "deleting #{key}: #{text(reason)}"}
    end
  end

  defp kind_call(store, fun, args) do
    if Code.ensure_loaded?(store.mod) and function_exported?(store.mod, fun, length(args)),
      do: apply(store.mod, fun, args),
      else: {:error, "a #{store.kind} store keeps no cards here (#{fun})"}
  end

  # ------------------------------------------------------------------ probing

  @doc """
  Finds out whether exclusive puts are exclusive in an object store, by
  trying it: the probe an object store's `probe/1` can use.

  `ops` are the store's own `put`, `get` and `delete`. Under a scratch prefix
  of its own (`_probe/<32 hex>/`), one key is put exclusively twice, which
  must give `:ok` and then `{:error, :exists}` and keep the first body; then,
  for each of `rounds:` (default 2) fresh keys, `racers:` (default 8)
  processes put it exclusively at once, which must give exactly one `:ok`
  and an object that is wholly the winner's body. Anything else is
  `cas: false`. A store that fails is `{:error, reason}`. Everything the
  probe wrote is deleted before it returns.
  """
  @spec probe_cas(ops(), keyword()) :: {:ok, %{cas: boolean()}} | {:error, term()}
  def probe_cas(%{put: put, get: get, delete: delete}, opts \\ [])
      when is_function(put, 3) and is_function(get, 1) and is_function(delete, 1) do
    rounds = Keyword.get(opts, :rounds, @probe_rounds)
    racers = Keyword.get(opts, :racers, @probe_racers)
    scratch = "_probe/" <> random_id() <> "/"
    once = scratch <> "once"
    races = for round <- 1..rounds//1, do: scratch <> "race-#{round}"

    result =
      with {:ok, true} <- exclusive_once(put, get, once) do
        Enum.reduce_while(races, {:ok, true}, fn key, _ ->
          case race(put, get, key, racers) do
            {:ok, true} -> {:cont, {:ok, true}}
            other -> {:halt, other}
          end
        end)
      end

    cleanup =
      Enum.reduce_while([once | races], :ok, fn key, :ok ->
        case delete.(key) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, "removing what the probe wrote: #{text(reason)}"}}
        end
      end)

    case {result, cleanup} do
      {{:ok, cas}, :ok} -> {:ok, %{cas: cas}}
      {{:error, _} = error, _} -> error
      {_, error} -> error
    end
  end

  defp exclusive_once(put, get, key) do
    with {:first, :ok} <- {:first, put.(key, "first", exclusive: true)},
         {:second, {:error, :exists}} <- {:second, put.(key, "second", exclusive: true)} do
      case get.(key) do
        {:ok, "first"} -> {:ok, true}
        {:ok, _replaced} -> {:ok, false}
        {:error, :not_found} -> {:ok, false}
        {:error, reason} -> {:error, reason}
      end
    else
      # A fresh key that is said to exist, or a second put that wins.
      {:first, {:error, :exists}} -> {:ok, false}
      {:second, :ok} -> {:ok, false}
      {_, {:error, reason}} -> {:error, reason}
      {_, other} -> {:error, "an exclusive put answered #{inspect(other)}"}
    end
  end

  # `racers` processes wait for one message and then put `key` exclusively,
  # each with a body of its own. A put that raises is an answer about the
  # store, not a crash of the caller: the racer catches it, and is monitored
  # rather than linked.
  defp race(put, get, key, racers) do
    go = make_ref()
    parent = self()

    racers =
      for i <- 1..racers//1 do
        body = "racer #{i} " <> String.duplicate("x", i * 13)

        {pid, monitor} =
          spawn_monitor(fn ->
            receive do
              ^go -> send(parent, {go, self(), attempt(put, key, body)})
            end
          end)

        {body, pid, monitor}
      end

    Enum.each(racers, fn {_body, pid, _monitor} -> send(pid, go) end)
    deadline = System.monotonic_time(:millisecond) + @probe_timeout
    results = for {body, pid, monitor} <- racers, do: {body, answer(go, pid, monitor, deadline)}
    judge(get, key, results)
  end

  defp attempt(put, key, body) do
    {:ok, put.(key, body, exclusive: true)}
  catch
    kind, reason -> {:exit, {kind, reason}}
  end

  defp answer(go, pid, monitor, deadline) do
    receive do
      {^go, ^pid, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:exit, reason}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        nil
    end
  end

  defp judge(get, key, results) do
    winners = for {body, {:ok, :ok}} <- results, do: body

    failures =
      for {_body, reply} <- results,
          not match?({:ok, :ok}, reply) and not match?({:ok, {:error, :exists}}, reply),
          do: reply

    case {failures, winners} do
      {[{:ok, {:error, reason}} | _], _} ->
        {:error, reason}

      {[nil | _], _} ->
        {:error, "an exclusive put did not answer within #{@probe_timeout} ms"}

      {[{:exit, reason} | _], _} ->
        {:error, "an exclusive put crashed: #{inspect(reason)}"}

      {[{:ok, other} | _], _} ->
        {:error, "an exclusive put answered #{inspect(other)}"}

      {[], [winner]} ->
        case get.(key) do
          {:ok, ^winner} -> {:ok, true}
          {:ok, _other} -> {:ok, false}
          {:error, :not_found} -> {:ok, false}
          {:error, reason} -> {:error, reason}
        end

      {[], _none_or_many} ->
        {:ok, false}
    end
  end

  # ------------------------------------------------------------------ helpers

  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp text(reason) when is_binary(reason), do: reason
  defp text(:not_found), do: "not found"
  defp text(:exists), do: "it already exists"
  defp text(reason), do: inspect(reason)
end
