defmodule Aerotow.Flight.Copy do
  @moduledoc """
  A flight's working copy: the database a flight has open, and the files
  glider keeps beside it.

  This is the one place a working copy is made, opened, shipped, measured,
  moved and removed, and the one place that decides where its pages live
  (`decide/3`). The flight's life cycle (`Aerotow.Flight`) is the same in
  every mode; what differs is done here.

  ## Where the pages live

    * `"memory"` - the glider is a graph in RAM, opened with a log
      (`Glider.open/1` with `log: true`) and at most the instance's
      `max_memory`. It is restored straight into memory
      (`Glider.Replication.restore/3` to `:memory`) and shipped from its
      handle. Nothing of it is under `flights/`
    * `"disk"` - the glider is a working copy under `flights/`, opened with
      `Glider.open/2`; with a hot set (`hot:`, bytes) it is opened with
      `hot_size:`, and glider keeps its list of hot pages beside the file
      (`-hot`), puts it in each base it ships and lays it beside a copy it
      restores, so a launch from a base starts warm

  The replica in the store is the same either way: a glider flown in memory
  on one flight can be flown from disk on the next, and back.

  ## Where it is

  A glider homed in a `dir` or `s3` store is copied to

      <instance dir>/flights/<store name>/<ref>.gldb

  and glider keeps `-wal/`, `-data/`, `-stream/`, `-tmp/` and `.lock`
  beside it. A small `<ref>.flight.json` beside those says which store, ref
  and flight the copy belongs to, so a copy left behind by a flight that
  died can be told apart and carried into the next one. A copy whose
  flight was lost with log that never shipped is moved, whole, to

      <instance dir>/orphans/<store name>/<ref>.<flight>.gldb

  with its siblings and `<ref>.<flight>.flight.json`.

  A memory flight has no file to move. When it is lost holding log that
  never shipped, what it has is written, before its handle is closed, as a
  replica in a directory (glider's own layout, a base and nothing after
  it), with the same marker beside it:

      <instance dir>/orphans/<store name>/<ref>.<flight>.replica/

  Such a replica is carried as a copy is (R15): restored, into memory or to
  disk, and the flight's lineage goes on from it.

  A glider homed in a `file` store has no copy: its file,
  `<root>/<ref>.gldb`, is opened where it lies, and nothing here removes it.
  """

  alias Aerotow.{Card, Instance, Ref, Store}

  # What glider keeps beside a database, and what a restore leaves while it
  # runs. The database itself is the empty suffix.
  @siblings ["", "-wal", "-data", "-stream", "-tmp", "-hot", ".lock", ".restoring"]
  @marker ".flight.json"
  @format 1
  @max_marker 4_096

  @typedoc """
  Where a flight's pages live: `"memory"` or `"disk"`, the hot set to keep
  when on disk (bytes, or `nil` for none), the page cache it may use when
  on disk (the instance's `cache_size`; `nil` is glider's default), and
  whether the choice was `"auto"`'s (which flies a glider that does not fit
  in memory from disk instead).
  """
  @type mode :: %{
          mode: String.t(),
          hot: pos_integer() | nil,
          cache: pos_integer() | nil,
          auto: boolean()
        }

  @typedoc """
  What `measure/1` reads from an open glider: the bytes its pages take in
  memory (`nil` for one on disk), and its hot set's counters (`nil` with
  none).
  """
  @type measured :: %{memory: non_neg_integer() | nil, hot: map() | nil}

  @typedoc "What a working copy's `.flight.json` says."
  @type marker :: %{store: String.t(), ref: Ref.t(), flight: pos_integer()}

  @typedoc "What one shipping pass sent."
  @type shipped :: %{
          generation: String.t(),
          position: non_neg_integer(),
          bases: non_neg_integer(),
          segments: non_neg_integer(),
          bytes: non_neg_integer(),
          lag: non_neg_integer()
        }

  @hot_counters [
    hot_capacity: "hot_capacity",
    hot_pages: "hot_pages",
    hot_hits: "hot_hits",
    promotions: "promotions",
    demotions: "demotions",
    prewarmed: "prewarmed"
  ]

  # ------------------------------------------------------------------ the mode

  @doc """
  Where a glider's pages live on the flight that is launching it: the one
  place this is decided.

  `mode` is the first of these that is set: the instance's `mode:`, the
  store's `mode:` option, the card's `mode` (a card always has one;
  `"auto"` unless somebody changed it). `hot` is chosen the same way from
  the instance's `hot:`, the store's `hot:` and the card's `hot`; `0` at
  any of them is "no hot set", and stops the search there.

    * `"auto"` is `"memory"` when the card says the glider is smaller than
      the instance's `memory_threshold`, which a new glider (no size yet,
      `bytes: 0`) is, and `"disk"` otherwise
    * a glider in a `file` store is always `"disk"`: its file is opened
      where it lies
    * `hot` applies to `"disk"` only
    * `disk: true` (an option) flies it from disk whatever the rest say: an
      adopted file, a carried copy, and a glider `"auto"` found does not
      fit in memory

  The card read is the one in the store when the launch starts, so a
  change made with `update/3` takes effect at the next launch, never in
  the middle of a flight.

      iex> instance = %Aerotow.Instance{name: :t, id: "", dir: "/w"}
      iex> store = %Aerotow.Store{name: "s", kind: :dir, url: "/s", mod: nil}
      iex> card = %Aerotow.Card{ref: "a", bytes: 100 * 1024 * 1024, hot: 1_048_576}
      iex> Aerotow.Flight.Copy.decide(instance, store, card)
      %{mode: "disk", hot: 1_048_576, cache: nil, auto: true}
      iex> Aerotow.Flight.Copy.decide(%{instance | mode: "memory"}, %{store | mode: "disk"}, card)
      %{mode: "memory", hot: nil, cache: nil, auto: false}
      iex> Aerotow.Flight.Copy.decide(instance, store, %{card | bytes: 0}, disk: true)
      %{mode: "disk", hot: 1_048_576, cache: nil, auto: true}
  """
  @spec decide(Instance.t(), Store.t(), Card.t(), keyword()) :: mode()
  def decide(%Instance{} = instance, %Store{} = store, %Card{} = card, opts \\ []) do
    wanted = instance.mode || store.mode || card.mode || "auto"
    hot = Enum.find([instance.hot, store.hot, card.hot], &(&1 != nil))

    mode =
      cond do
        store.kind == :file or Keyword.get(opts, :disk, false) -> "disk"
        wanted == "auto" and (card.bytes || 0) < instance.memory_threshold -> "memory"
        wanted == "auto" -> "disk"
        true -> wanted
      end

    %{
      mode: mode,
      hot: if(mode == "disk" and is_integer(hot) and hot > 0, do: hot),
      cache: if(mode == "disk", do: instance.cache_size),
      auto: wanted == "auto"
    }
  end

  @doc """
  Whether a reason glider gave is a memory graph's "it does not fit": past
  `max_memory`.
  """
  @spec full?(term()) :: boolean()
  def full?(reason) when is_binary(reason), do: String.contains?(reason, "max_memory is")
  def full?({:launch, reason}), do: full?(reason)
  def full?(_reason), do: false

  # ------------------------------------------------------------------ paths

  @doc """
  Where a glider's database is while it is aloft here: its working copy for
  an object store, its own file for a `file` store.
  """
  @spec path(Instance.t(), Store.t(), Ref.t()) :: Path.t()
  def path(%Instance{}, %Store{kind: :file} = store, ref), do: Store.File.path(store, ref)

  def path(%Instance{dir: dir}, %Store{name: name}, ref),
    do: Path.join([dir, "flights", name, Ref.parse!(ref) <> ".gldb"])

  @doc "Where a copy of flight `n` is kept when its flight was lost with log that never shipped."
  @spec orphan_path(Instance.t(), Store.t(), Ref.t(), pos_integer()) :: Path.t()
  def orphan_path(%Instance{dir: dir}, %Store{name: name}, ref, n),
    do: Path.join([dir, "orphans", name, "#{Ref.parse!(ref)}.#{n}.gldb"])

  @doc """
  Where a memory flight `n` writes what it holds when it is lost with log
  that never shipped: a directory replica.
  """
  @spec orphan_replica_path(Instance.t(), Store.t(), Ref.t(), pos_integer()) :: Path.t()
  def orphan_replica_path(%Instance{dir: dir}, %Store{name: name}, ref, n),
    do: Path.join([dir, "orphans", name, "#{Ref.parse!(ref)}.#{n}.replica"])

  @doc """
  The `.flight.json` beside a copy, or beside a memory flight's replica.

      iex> Aerotow.Flight.Copy.marker_path("/w/flights/assets/a/b.gldb")
      "/w/flights/assets/a/b.flight.json"
      iex> Aerotow.Flight.Copy.marker_path("/w/orphans/assets/a/b.3.replica")
      "/w/orphans/assets/a/b.3.flight.json"
  """
  @spec marker_path(Path.t()) :: Path.t()
  def marker_path(path), do: base(path) <> @marker

  defp base(path) do
    if replica?(path),
      do: String.replace_suffix(path, ".replica", ""),
      else: String.replace_suffix(path, ".gldb", "")
  end

  @doc """
  Whether `path` names a memory flight's replica (`….replica`) rather than
  a copy's database (`….gldb`).
  """
  @spec replica?(Path.t()) :: boolean()
  def replica?(path), do: String.ends_with?(path, ".replica")

  @doc """
  The copy a marker belongs to: the replica beside it when there is one,
  the database otherwise.
  """
  @spec of_marker(Path.t()) :: Path.t()
  def of_marker(marker) do
    base = String.replace_suffix(marker, @marker, "")
    if File.dir?(base <> ".replica"), do: base <> ".replica", else: base <> ".gldb"
  end

  @doc "Whether anything of a working copy is at `path`: the database, a sibling or its marker."
  @spec exists?(Path.t()) :: boolean()
  def exists?(path), do: Enum.any?(files(path), &present?/1)

  defp files(path), do: Enum.map(@siblings, &(path <> &1)) ++ [marker_path(path)]

  defp present?(path), do: match?({:ok, _}, File.lstat(path))

  # ------------------------------------------------------------------ the marker

  @doc "Writes the copy's `.flight.json`, replacing one that is there."
  @spec write_marker(Path.t(), Store.t(), Ref.t(), pos_integer()) :: :ok | {:error, String.t()}
  def write_marker(path, %Store{name: name}, ref, n) do
    marker = marker_path(path)

    body =
      IO.iodata_to_binary([
        "{\n  \"format\": #{@format},\n  \"store\": ",
        JSON.encode!(name),
        ",\n  \"ref\": ",
        JSON.encode!(ref),
        ",\n  \"flight\": #{n}\n}\n"
      ])

    tmp = marker <> ".tmp"

    with :ok <- mkdir(Path.dirname(marker)),
         :ok <- file(File.write(tmp, body), "writing #{tmp}"),
         :ok <- file(File.rename(tmp, marker), "renaming #{tmp}") do
      :ok
    end
  end

  @doc """
  Reads a copy's `.flight.json`. It is input: everything in it is checked,
  and nothing in it becomes an atom.
  """
  @spec read_marker(Path.t()) :: {:ok, marker()} | {:error, String.t()}
  def read_marker(path) do
    marker = marker_path(path)

    with {:ok, body} <- read_small(marker),
         {:ok, %{"format" => @format, "store" => store, "ref" => ref, "flight" => n}}
         when is_binary(store) and is_integer(n) and n > 0 <- decode(body, marker),
         {:ok, ref} <- Ref.parse(ref) do
      {:ok, %{store: store, ref: ref, flight: n}}
    else
      {:ok, _other} -> {:error, "#{marker} is not a working copy's marker"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_small(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_marker ->
        file(File.read(path), "reading #{path}")

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "#{path} is too large to be a working copy's marker"}

      {:ok, _} ->
        {:error, "#{path} is not a file"}

      {:error, reason} ->
        {:error, "reading #{path}: #{posix(reason)}"}
    end
  end

  defp decode(body, path) do
    case JSON.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, "#{path} is not JSON"}
    end
  end

  # ------------------------------------------------------------------ making one

  @doc """
  Opens the database at `path`, creating an empty one when there is none,
  with the hot set and page cache a mode gives (`decide/4`); `nil` for
  glider's defaults.
  """
  @spec open(Path.t(), mode() | nil) :: {:ok, Glider.db()} | {:error, String.t()}
  def open(path, mode \\ nil) do
    opts =
      case mode do
        %{hot: hot, cache: cache} ->
          for {key, value} <- [hot_size: hot, cache_size: cache], value != nil, do: {key, value}

        nil ->
          []
      end

    with :ok <- mkdir(Path.dirname(path)) do
      case Glider.open(path, opts) do
        {:ok, db} -> {:ok, db}
        {:error, reason} -> {:error, "opening #{path}: #{reason}"}
      end
    end
  end

  @doc """
  A new, empty graph in memory, keeping the log it ships, of at most the
  instance's `max_memory`.
  """
  @spec open_memory(Instance.t()) :: {:ok, Glider.db()} | {:error, String.t()}
  def open_memory(%Instance{max_memory: max}) do
    case Glider.open(max_memory: max, log: true) do
      {:ok, db} -> {:ok, db}
      {:error, reason} -> {:error, "opening a graph in memory: #{reason}"}
    end
  end

  @doc """
  Rebuilds a database at `path` from the replica at `url`: the newest
  generation there, its newest base and the log after it. Answers where the
  restored state is: its generation and how far its log goes.
  """
  @spec restore(String.t(), keyword(), Path.t()) ::
          {:ok, %{generation: String.t(), position: non_neg_integer()}} | {:error, String.t()}
  def restore(url, opts, path) do
    with :ok <- mkdir(Path.dirname(path)),
         {:ok, generations} <- Glider.Replication.generations(url, opts),
         {:ok, generation} <- newest(generations, url),
         {:ok, report} <-
           Glider.Replication.restore(url, path, [generation: generation] ++ opts) do
      {:ok, %{generation: report.generation, position: report.through}}
    end
  end

  @doc """
  Rebuilds a graph in memory from the replica at `url`, as `restore/3` does
  on disk, of at most the instance's `max_memory`. A replica that does not
  fit is glider's error (`full?/1`), and nothing of it stays allocated.
  Answers the open handle and where the restored state is.
  """
  @spec restore_memory(String.t(), keyword(), Instance.t()) ::
          {:ok, %{db: Glider.db(), generation: String.t(), position: non_neg_integer()}}
          | {:error, String.t()}
  def restore_memory(url, opts, %Instance{max_memory: max}) do
    with {:ok, generations} <- Glider.Replication.generations(url, opts),
         {:ok, generation} <- newest(generations, url),
         {:ok, report} <-
           Glider.Replication.restore(
             url,
             :memory,
             [generation: generation, max_memory: max] ++ opts
           ) do
      {:ok, %{db: report.db, generation: report.generation, position: report.through}}
    end
  end

  defp newest([], url), do: {:error, "#{url} holds no whole base"}
  defp newest(generations, _url), do: {:ok, List.last(generations)}

  @doc """
  Copies a database that nothing has open, with the log and data glider
  keeps beside it, to `path`. The original is only read.
  """
  @spec adopt(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def adopt(from, path) do
    cond do
      not match?({:ok, %File.Stat{type: :regular}}, File.lstat(from)) ->
        {:error, "#{from} is not a database file"}

      present?(from <> ".lock") ->
        {:error, "#{from} is open (#{from}.lock is there): close it before it is adopted"}

      true ->
        with :ok <- mkdir(Path.dirname(path)) do
          Enum.reduce_while(["", "-wal", "-data"], :ok, fn suffix, :ok ->
            case copy(from <> suffix, path <> suffix) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
    end
  end

  defp copy(from, to) do
    case File.lstat(from) do
      {:ok, %File.Stat{type: :regular}} ->
        file(File.cp(from, to), "copying #{from}")

      {:ok, %File.Stat{type: :directory}} ->
        case File.cp_r(from, to) do
          {:ok, _} -> :ok
          {:error, reason, file} -> {:error, "copying #{file}: #{posix(reason)}"}
        end

      {:ok, _} ->
        {:error, "#{from} is neither a file nor a directory"}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "copying #{from}: #{posix(reason)}"}
    end
  end

  # ------------------------------------------------------------------ shipping

  @doc """
  One shipping pass: what the database at `path` (or, for a memory flight,
  `nil`, the graph behind `db`) has committed and the replica at `url`
  lacks is shipped there. A replica with nothing in it gets a whole base
  first. Answers what was sent and where the replica now ends. It waits
  for a slot first (`Aerotow.Flight.Slots`).

  `rebase: true` ships a new base whatever the replica has, from a
  checkpoint taken now: how a flight with a hot set puts its hot list in
  the store as it lands. Nobody may hold a transaction on `db` then.
  """
  @spec ship(Path.t() | nil, Glider.db(), String.t(), keyword()) ::
          {:ok, shipped()} | {:error, String.t()}
  def ship(path, db, url, opts) do
    Aerotow.Flight.Slots.run(fn -> sync(path, db, url, opts) end)
  end

  defp sync(path, db, url, opts) do
    {rebase, opts} = Keyword.pop(opts, :rebase, false)

    pass =
      cond do
        path == nil ->
          Glider.Replication.sync(db, url, [force_snapshot: rebase] ++ opts)

        rebase ->
          with :ok <- Glider.checkpoint(db),
               do: Glider.Replication.sync(path, url, [db: db, force_snapshot: true] ++ opts)

        true ->
          Glider.Replication.sync(path, url, [db: db] ++ opts)
      end

    with {:ok, report} <- pass,
         {:ok, listing} <- Glider.Replication.listing(url, report.generation, opts) do
      {:ok,
       %{
         generation: report.generation,
         position: listing.complete_to,
         bases: report.bases_uploaded,
         segments: report.segments_uploaded,
         bytes: report.bytes,
         lag: report.lag_bytes || 0
       }}
    end
  end

  @doc """
  Writes what a memory graph holds to a directory replica at `to` (a whole
  base) and the marker of `store`, `ref` and flight `n` beside it: what a
  memory flight lost with log that never shipped leaves, so that it can be
  carried. Nothing may be at `to`.
  """
  @spec keep_memory(Glider.db(), Path.t(), Store.t(), Ref.t(), pos_integer()) ::
          :ok | {:error, String.t()}
  def keep_memory(db, to, store, ref, n) do
    if exists?(to) do
      {:error, "#{to} is taken: a working copy is there"}
    else
      with :ok <- mkdir(to),
           :ok <- write_marker(to, store, ref, n),
           {:ok, %{bases_uploaded: bases}} when bases > 0 <-
             Glider.Replication.sync(db, to, force_snapshot: true) do
        :ok
      else
        {:ok, _report} ->
          _ = remove(to)
          {:error, "writing #{to}: the replica got no base"}

        {:error, reason} ->
          _ = remove(to)
          {:error, "writing #{to}: #{reason}"}
      end
    end
  end

  @doc """
  Whether the memory flight's replica at `path` holds a whole base, so that
  it can be carried.
  """
  @spec replica_whole?(Path.t()) :: :ok | {:error, String.t()}
  def replica_whole?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case Glider.Replication.generations(path) do
          {:ok, [_ | _]} -> :ok
          {:ok, []} -> {:error, "#{path} holds no whole base"}
          {:error, reason} -> {:error, "reading #{path}: #{reason}"}
        end

      _ ->
        {:error, "#{path} is not a replica"}
    end
  end

  # ------------------------------------------------------------------ measuring

  @doc """
  What an open glider takes and how its hot set is doing, from
  `Glider.stats/1`: `memory` is its `"memory_bytes"` (a graph in memory
  only), `hot` its hot set's counters (`"hot_capacity"`, `"hot_pages"`,
  `"hot_hits"`, `"promotions"`, `"demotions"`, `"prewarmed"`; a glider with
  a hot set only). `nil` when the handle cannot say.
  """
  @spec measure(Glider.db()) :: measured() | nil
  def measure(db) do
    case Glider.stats(db) do
      {:ok, stats} ->
        hot =
          if Map.has_key?(stats, "hot_capacity"),
            do: Map.new(@hot_counters, fn {key, name} -> {key, stats[name] || 0} end)

        %{memory: stats["memory_bytes"], hot: hot}

      {:error, _} ->
        nil
    end
  end

  # ------------------------------------------------------------------ on disk

  @doc "How many bytes the database at `path` and glider's files beside it take on disk."
  @spec bytes(Path.t() | nil) :: non_neg_integer()
  def bytes(nil), do: 0

  def bytes(path) do
    ["", "-wal", "-data"]
    |> Enum.map(&size(path <> &1))
    |> Enum.sum()
  end

  defp size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> names |> Enum.map(&size(Path.join(path, &1))) |> Enum.sum()
          {:error, _} -> 0
        end

      _ ->
        0
    end
  end

  @doc """
  Removes a working copy: the database, everything glider keeps beside it,
  and its marker. Nothing may have it open.
  """
  @spec remove(Path.t() | nil) :: :ok | {:error, String.t()}
  def remove(nil), do: :ok

  def remove(path) do
    Enum.reduce_while(files(path), :ok, fn file, :ok ->
      case File.rm_rf(file) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason, at} -> {:halt, {:error, "removing #{at}: #{posix(reason)}"}}
      end
    end)
  end

  @doc """
  Moves a working copy whole, the database, its siblings and its marker,
  from `from` to `to`. Nothing may have it open, and nothing may be at `to`.
  A stale `.lock` is not moved.
  """
  @spec move(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def move(from, from), do: :ok

  def move(from, to) do
    cond do
      exists?(to) ->
        {:error, "#{to} is taken: a working copy is there"}

      true ->
        _ = File.rm(from <> ".lock")
        pairs = Enum.zip(files(from), files(to))

        with :ok <- mkdir(Path.dirname(to)) do
          Enum.reduce_while(pairs, :ok, fn {a, b}, :ok ->
            if present?(a) do
              case File.rename(a, b) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, "moving #{a}: #{posix(reason)}"}}
              end
            else
              {:cont, :ok}
            end
          end)
        end
    end
  end

  # ------------------------------------------------------------------ helpers

  defp mkdir(dir), do: file(File.mkdir_p(dir), "making #{dir}")

  defp file(:ok, _what), do: :ok
  defp file({:ok, value}, _what), do: {:ok, value}
  defp file({:error, reason}, what), do: {:error, "#{what}: #{posix(reason)}"}

  defp posix(reason) when is_atom(reason), do: reason |> :file.format_error() |> List.to_string()
  defp posix(reason), do: inspect(reason)
end
