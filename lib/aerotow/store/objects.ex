defmodule Aerotow.Store.Objects do
  @moduledoc """
  What a store of objects can do: `Aerotow.Store.Dir` on a disk,
  `Aerotow.Store.S3` in a bucket. Cards, flight records and the replicas
  glider ships all live in one.

  Keys are relative to the store's root, use `/`, and are built with
  `Aerotow.Store.Layout` from refs that have been parsed; an implementation
  may assume a key has no empty, `.` or `..` segment and must still refuse
  one that does.

  `config` is whatever `init/3` returned. It may hold credentials, so it is
  never logged, never put in the catalog and never sent to a peer.
  """

  @type config :: map()
  @type key :: String.t()

  @typedoc """
  One object in a listing. `version` changes whenever the object's content
  does (an ETag, or a size and modification time): a scan uses it to skip
  cards it has already read.
  """
  @type object :: %{key: key(), size: non_neg_integer(), version: String.t()}

  @doc """
  Checks the url and options and returns the store's config. `opts` are the
  options the store was added with (`endpoint:`, `access_key_id:`, …).
  """
  @callback init(name :: String.t(), url :: String.t(), opts :: keyword()) ::
              {:ok, config()} | {:error, String.t()}

  @doc "The whole object, or `{:error, :not_found}`."
  @callback get(config(), key()) :: {:ok, binary()} | {:error, :not_found | term()}

  @doc """
  Writes an object. A reader never sees half of one.

  With `exclusive: true` the object is created only if nothing is there:
  exactly one of several writers racing for the same key gets `:ok`, and the
  rest get `{:error, :exists}`. That is what makes a flight record a lease.
  """
  @callback put(config(), key(), iodata(), opts :: [exclusive: boolean()]) ::
              :ok | {:error, :exists | term()}

  @doc "Deletes an object. Deleting one that is not there is `:ok`."
  @callback delete(config(), key()) :: :ok | {:error, term()}

  @doc """
  The objects whose keys start with `prefix`, in key order.

  With `delimiter: true`, only what is directly under `prefix`: objects with
  no further `/` in the rest of their key, and in `prefixes` the "directories"
  (each ending in `/`) that hold everything else.
  """
  @callback list(config(), prefix :: String.t(), opts :: [delimiter: boolean()]) ::
              {:ok, %{objects: [object()], prefixes: [String.t()]}} | {:error, term()}

  @doc """
  The replica url and options `Glider.Replication.sync/3` and `restore/3`
  take for everything under `prefix` (no trailing slash): a path for a
  directory, `s3://bucket/…` with `endpoint:` and keys for a bucket.
  """
  @callback replica(config(), prefix :: String.t()) :: {url :: String.t(), opts :: keyword()}

  @doc """
  Finds out what the store can do by trying it. `cas` is whether an
  exclusive put really is exclusive there.
  """
  @callback probe(config()) :: {:ok, %{cas: boolean()}} | {:error, term()}
end
