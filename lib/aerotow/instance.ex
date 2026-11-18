defmodule Aerotow.Instance do
  @moduledoc """
  One running aerotow: what every part of it needs to know about the whole.

  An instance is named (`name:` when it is started) and everything in it is
  found from that name: its processes, its table of stores, its clock. The
  struct is built once, when the instance starts, and does not change; it is
  kept where any process can read it without asking another process
  (`fetch/1`), so a statement never waits behind something that is busy.

  ## What is in it

    * `name` - the instance's name, an atom. It is what callers pass as `tow`
    * `id` - 32 hex digits that name this instance in flight records. Kept
      in `<dir>/instance.json`, so it survives a restart on the same disk
    * `dir` - the working directory: `catalog.gldb`, `flights/` (working
      copies of gliders aloft here), `orphans/`
    * `clock` - an `Aerotow.Clock`
    * `timing` - a lease's `ttl`, `margin` and `grace`, in milliseconds
    * `node`, `url` - how another instance reaches this one, written into
      flight records: this node's name when it is distributed, and the url
      its `Aerotow.Plug` is served at, when it has one
    * `catalog`, `registry`, `flights`, `tasks`, `server` - the registered
      names of its processes
    * `table` - its ETS table: stores (with their credentials) and what is
      aloft
    * the limits and intervals below

  ## Options an instance is started with

  | option | default | |
  |---|---|---|
  | `sync_interval` | 1,000 ms | a dirty flight ships this often |
  | `sync_timeout` | 300,000 ms | a shipping pass is given up after this |
  | `launch_timeout` | 300,000 ms | a caller waits this long for a launch |
  | `idle` | 300,000 ms | a flight nobody has used for this long lands |
  | `max_aloft` | 64 | flights open here before the least recently used land |
  | `budget` | `nil` | bytes of working copies before the same |
  | `scan_interval` | 60,000 ms | each store's cards are re-read this often; `nil` for never |
  | `retention` | 86,400,000 ms | older flights are deleted from a store after this |
  | `memory_threshold` | 64 MiB | under `mode: "auto"`, a glider smaller than this flies in memory |
  | `default_store` | `nil` | where `create/3` puts a glider that names no store |
  """

  @enforce_keys [:name, :id, :dir]
  defstruct name: nil,
            id: nil,
            dir: nil,
            clock: :system,
            timing: %{ttl: 30_000, margin: 5_000, grace: 5_000},
            node: nil,
            url: nil,
            catalog: nil,
            registry: nil,
            flights: nil,
            tasks: nil,
            server: nil,
            table: nil,
            sync_interval: 1_000,
            sync_timeout: 300_000,
            launch_timeout: 300_000,
            idle: 300_000,
            max_aloft: 64,
            budget: nil,
            scan_interval: 60_000,
            retention: 86_400_000,
            memory_threshold: 64 * 1024 * 1024,
            default_store: nil

  @type timing :: %{ttl: pos_integer(), margin: pos_integer(), grace: non_neg_integer()}

  @type t :: %__MODULE__{
          name: atom(),
          id: String.t(),
          dir: Path.t(),
          clock: Aerotow.Clock.t(),
          timing: timing(),
          node: String.t() | nil,
          url: String.t() | nil,
          catalog: atom(),
          registry: atom(),
          flights: atom(),
          tasks: atom(),
          server: atom(),
          table: atom(),
          sync_interval: pos_integer(),
          sync_timeout: pos_integer(),
          launch_timeout: pos_integer(),
          idle: pos_integer() | :infinity,
          max_aloft: pos_integer(),
          budget: pos_integer() | nil,
          scan_interval: pos_integer() | nil,
          retention: pos_integer(),
          memory_threshold: non_neg_integer(),
          default_store: String.t() | nil
        }

  @parts ~w(catalog registry flights tasks server table)a

  @doc """
  The registered names of an instance's processes and table, from its name.

      iex> Aerotow.Instance.names(MyApp.Aerotow).catalog
      MyApp.Aerotow.Catalog
  """
  @spec names(atom()) :: %{
          catalog: atom(),
          registry: atom(),
          flights: atom(),
          tasks: atom(),
          server: atom(),
          table: atom()
        }
  def names(name) when is_atom(name) do
    Map.new(@parts, fn part ->
      {part, Module.concat(name, part |> Atom.to_string() |> Macro.camelize())}
    end)
  end

  @doc """
  Checks a lease's timing: positive, and a margin and grace that leave room
  inside the ttl. A holder renews every `ttl / 3`, so the margin has to be
  less than two thirds of the ttl or a healthy flight would lose itself.
  """
  @spec check_timing(map()) :: {:ok, timing()} | {:error, String.t()}
  def check_timing(%{ttl: ttl, margin: margin, grace: grace})
      when is_integer(ttl) and is_integer(margin) and is_integer(grace) do
    cond do
      ttl <= 0 or margin <= 0 or grace < 0 ->
        {:error, "a lease's ttl and margin are positive and its grace is not negative"}

      margin * 3 >= ttl * 2 ->
        {:error,
         "a lease's margin (#{margin} ms) must be under two thirds of its ttl (#{ttl} ms)"}

      true ->
        {:ok, %{ttl: ttl, margin: margin, grace: grace}}
    end
  end

  def check_timing(_), do: {:error, "a lease's timing is %{ttl: ms, margin: ms, grace: ms}"}

  @doc "Makes a running instance findable by its name. Called once, by the instance, as it starts."
  @spec put(t()) :: :ok
  def put(%__MODULE__{name: name} = instance),
    do: :persistent_term.put({__MODULE__, name}, instance)

  @doc "Forgets an instance. Called as it stops."
  @spec delete(atom()) :: :ok
  def delete(name) do
    :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @doc "The running instance of that name."
  @spec fetch(atom()) :: {:ok, t()} | {:error, :not_running}
  def fetch(name) when is_atom(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      %__MODULE__{} = instance -> {:ok, instance}
      nil -> {:error, :not_running}
    end
  end

  @doc "Like `fetch/1`, raising `ArgumentError` when no instance of that name is running."
  @spec fetch!(atom()) :: t()
  def fetch!(name) do
    case fetch(name) do
      {:ok, instance} ->
        instance

      {:error, :not_running} ->
        raise ArgumentError, "no aerotow named #{inspect(name)} is running"
    end
  end
end
