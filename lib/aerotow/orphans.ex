defmodule Aerotow.Orphans do
  @moduledoc """
  What is kept in `<dir>/orphans/`: working copies that may hold log that
  never shipped, set aside rather than thrown away (R14).

      <dir>/orphans/<store>/<ref>.<flight>.gldb          the copy, with glider's files beside it
      <dir>/orphans/<store>/<ref>.<flight>.replica/      or a memory flight's replica, in its place
      <dir>/orphans/<store>/<ref>.<flight>.flight.json   its marker (`Aerotow.Flight.Copy`)
      <dir>/orphans/<store>/<ref>.<flight>.note.json     why it is here, when it was set aside
      <dir>/orphans/left-<unix ms>/…                     files found under flights/ that were no copy

  A copy gets here three ways: its flight was lost with log that never
  shipped (`Aerotow.Flight` moves it, and writes no note; a flight in
  memory has no copy to move, and writes what it holds as a replica in a
  directory instead); the instance
  started and found it under `flights/` and could not carry it; or a launch
  found it where its own copy goes and could not carry it
  (`Aerotow.Copies.set_aside/3`, which writes the note).

  An orphan whose flight is still the newest in its store is carried into
  the next flight (`Aerotow.Recovery`), which moves it out of here. Nothing
  else takes one away: an orphan is deleted only by `discard/2`.
  """

  alias Aerotow.{Clock, Instance, Ref}
  alias Aerotow.Flight.Copy

  @format 1
  @max_note 16_384
  @lost "its flight was lost with log that never shipped"
  @left "files found under flights/ that were no working copy"

  @typedoc """
  One orphan, as `list/1` gives it: `id` (what `discard/2` takes: its path
  under `orphans/`), the `ref`, `store` and `flight` its marker names
  (`nil` where they cannot be told), `when` it was set aside (unix ms),
  `why`, how many `bytes` it holds, its `path`, and `carry` (false once it
  was found not to open, so nobody tries again).
  """
  @type t :: %{
          id: String.t(),
          ref: Ref.t() | nil,
          store: String.t() | nil,
          flight: non_neg_integer() | nil,
          when: integer() | nil,
          why: String.t(),
          bytes: non_neg_integer(),
          path: Path.t(),
          carry: boolean()
        }

  @doc "The directory orphans are kept in."
  @spec dir(Instance.t()) :: Path.t()
  def dir(%Instance{dir: dir}), do: Path.join(dir, "orphans")

  @doc """
  The note beside an orphan.

      iex> Aerotow.Orphans.note_path("/w/orphans/assets/a/b.3.gldb")
      "/w/orphans/assets/a/b.3.note.json"
  """
  @spec note_path(Path.t()) :: Path.t()
  def note_path(path),
    do: String.replace_suffix(Copy.marker_path(path), ".flight.json", "") <> ".note.json"

  @doc """
  Writes why the copy at `path` is an orphan, with the time on the
  instance's clock. `carry: false` says it is not to be carried.
  """
  @spec note(Instance.t(), Path.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def note(%Instance{clock: clock}, path, why, opts \\ []) when is_binary(why) do
    body =
      JSON.encode!(%{
        "format" => @format,
        "why" => why,
        "at" => Clock.now(clock),
        "carry" => Keyword.get(opts, :carry, true)
      })

    note = note_path(path)
    tmp = note <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(note)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, note) do
      :ok
    else
      {:error, reason} -> {:error, "writing #{note}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Removes the note of a copy that is no longer an orphan (it was carried)."
  @spec forget_note(Path.t()) :: :ok
  def forget_note(path) do
    unless Copy.exists?(path), do: _ = File.rm(note_path(path))
    :ok
  end

  @doc "Every orphan, oldest first."
  @spec list(Instance.t()) :: [t()]
  def list(%Instance{} = instance) do
    root = dir(instance)

    copies =
      root
      |> copies()
      |> Enum.map(&describe(root, &1))

    left =
      root
      |> Path.join("left-*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&describe_left(root, &1))

    Enum.sort_by(copies ++ left, &{&1.when || 0, &1.id})
  end

  @doc "The orphans of one glider in one store, highest flight first."
  @spec of(Instance.t(), String.t(), Ref.t()) :: [t()]
  def of(%Instance{} = instance, store, ref) do
    root = dir(instance)
    base = Path.join([root, store, ref])
    # Listed rather than globbed: a store's name may hold what a glob reads.
    prefix = Path.basename(base) <> "."

    case File.ls(Path.dirname(base)) do
      {:ok, names} -> names
      {:error, _} -> []
    end
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.flat_map(fn name ->
      cond do
        String.ends_with?(name, ".flight.json") ->
          [name |> Path.expand(Path.dirname(base)) |> Copy.of_marker() |> Path.basename()]

        String.ends_with?(name, [".gldb", ".replica"]) ->
          [name]

        true ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.map(&Path.join(Path.dirname(base), &1))
    |> Enum.map(&describe(root, &1))
    |> Enum.filter(&(&1.store == store and &1.ref == ref))
    |> Enum.sort_by(&(&1.flight || 0), :desc)
  end

  @doc """
  Deletes the orphan `id` (as `list/1` gives it): the copy, glider's files
  beside it, its marker and its note. The only thing that deletes one.
  """
  @spec discard(Instance.t(), String.t()) :: :ok | {:error, :not_found | String.t()}
  def discard(%Instance{} = instance, id) when is_binary(id) do
    # Only an id that is listed now is a path: nothing from outside is joined.
    case Enum.find(list(instance), &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      %{path: path} = orphan ->
        result = if orphan.ref, do: Copy.remove(path), else: rm_rf(path)

        with :ok <- result do
          _ = File.rm(note_path(path))
          tidy(dir(instance))
          :ok
        end
    end
  end

  def discard(_instance, _id), do: {:error, :not_found}

  # ------------------------------------------------------------------ reading

  # The copies under orphans/: databases, replicas and markers, each as the
  # path of its database or replica. What is inside glider's own directories
  # is not a copy.
  defp copies(root) do
    if File.dir?(root) do
      root
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&String.starts_with?(Path.relative_to(&1, root), "left-"))
      |> Enum.flat_map(fn path ->
        cond do
          String.contains?(path, [".gldb-", ".gldb/", ".gldb.restoring", ".replica/"]) ->
            []

          String.ends_with?(path, ".flight.json") ->
            [Copy.of_marker(path)]

          String.ends_with?(path, [".gldb", ".replica"]) ->
            [path]

          true ->
            []
        end
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  defp describe(root, path) do
    {ref, store, flight} =
      case Copy.read_marker(path) do
        {:ok, marker} -> {marker.ref, marker.store, marker.flight}
        {:error, _} -> {nil, nil, nil}
      end

    note = read_note(path)

    %{
      id: Path.relative_to(path, root),
      ref: ref,
      store: store,
      flight: flight,
      when: note[:at] || modified(path),
      why: note[:why] || @lost,
      bytes: Copy.bytes(path),
      path: path,
      carry: Map.get(note, :carry, true) and ref != nil
    }
  end

  defp describe_left(root, path) do
    name = Path.basename(path)

    at =
      case Integer.parse(String.replace_prefix(name, "left-", "")) do
        {ms, ""} -> ms
        _ -> modified(path)
      end

    %{
      id: Path.relative_to(path, root),
      ref: nil,
      store: nil,
      flight: nil,
      when: at,
      why: @left,
      bytes: path |> files() |> Enum.map(&size/1) |> Enum.sum(),
      path: path,
      carry: false
    }
  end

  # A note is input: what is not one is no note.
  defp read_note(path) do
    note = note_path(path)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_note <- File.stat(note),
         {:ok, body} <- File.read(note),
         {:ok, %{"format" => @format, "why" => why} = map} when is_binary(why) <-
           JSON.decode(body) do
      %{
        why: why,
        at: if(is_integer(map["at"]), do: map["at"]),
        carry: map["carry"] != false
      }
    else
      _ -> %{}
    end
  end

  defp modified(path) do
    [Copy.marker_path(path), path]
    |> Enum.find_value(fn file ->
      case File.stat(file, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} -> mtime * 1000
        {:error, _} -> nil
      end
    end)
  end

  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp size(file) do
    case File.stat(file) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> 0
    end
  end

  defp rm_rf(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, reason, at} -> {:error, "removing #{at}: #{:file.format_error(reason)}"}
    end
  end

  @doc false
  # Directories left empty under `root` go, and `root` too when it is empty.
  @spec tidy(Path.t()) :: :ok
  def tidy(root) do
    if File.dir?(root) do
      root
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.concat([root])
      |> Enum.each(&File.rmdir/1)
    end

    :ok
  end
end
