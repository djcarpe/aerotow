defmodule Aerotow.Flight.Copy do
  @moduledoc """
  A flight's working copy: the database a flight has open, and the files
  glider keeps beside it.

  This is the one place a working copy is made, opened, shipped, measured,
  moved and removed. Every working copy is flown from disk today (`mode/0`
  is `"disk"`); a memory flight is another way of doing these same things,
  and is added here without touching the flight's life cycle.

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

  A glider homed in a `file` store has no copy: its file,
  `<root>/<ref>.gldb`, is opened where it lies, and nothing here removes it.
  """

  alias Aerotow.{Instance, Ref, Store}

  # What glider keeps beside a database, and what a restore leaves while it
  # runs. The database itself is the empty suffix.
  @siblings ["", "-wal", "-data", "-stream", "-tmp", ".lock", ".restoring"]
  @marker ".flight.json"
  @format 1
  @max_marker 4_096

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

  @doc "How the pages of a working copy are held: on disk, for now."
  @spec mode() :: String.t()
  def mode, do: "disk"

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
  The `.flight.json` beside a copy.

      iex> Aerotow.Flight.Copy.marker_path("/w/flights/assets/a/b.gldb")
      "/w/flights/assets/a/b.flight.json"
  """
  @spec marker_path(Path.t()) :: Path.t()
  def marker_path(path), do: String.replace_suffix(path, ".gldb", "") <> @marker

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

  @doc "Opens the database at `path`, creating an empty one when there is none."
  @spec open(Path.t()) :: {:ok, Glider.db()} | {:error, String.t()}
  def open(path) do
    with :ok <- mkdir(Path.dirname(path)) do
      case Glider.open(path) do
        {:ok, db} -> {:ok, db}
        {:error, reason} -> {:error, "opening #{path}: #{reason}"}
      end
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
  One shipping pass: what the database at `path` has committed and the
  replica at `url` lacks is shipped there. A replica with nothing in it gets
  a whole base first. Answers what was sent and where the replica now ends.
  It waits for a slot first (`Aerotow.Flight.Slots`).
  """
  @spec ship(Path.t(), Glider.db(), String.t(), keyword()) ::
          {:ok, shipped()} | {:error, String.t()}
  def ship(path, db, url, opts) do
    Aerotow.Flight.Slots.run(fn -> sync(path, db, url, opts) end)
  end

  defp sync(path, db, url, opts) do
    with {:ok, report} <- Glider.Replication.sync(path, url, [db: db] ++ opts),
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

  # ------------------------------------------------------------------ on disk

  @doc "How many bytes the database at `path` and glider's files beside it take on disk."
  @spec bytes(Path.t()) :: non_neg_integer()
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
  @spec remove(Path.t()) :: :ok | {:error, String.t()}
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
