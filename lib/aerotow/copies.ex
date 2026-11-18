defmodule Aerotow.Copies do
  @moduledoc """
  Working copies found on disk that no flight here is flying.

  A copy under `<dir>/flights/` belongs to a flight that ran here and did not
  land: the instance stopped, or its catalog died and took the flights with
  it, or the VM was killed. Such a copy may hold log that never shipped, so
  it is never deleted. If its flight is still the newest in its store it is
  carried into the next flight (R15, `Aerotow.Recovery`); otherwise it is
  set aside, whole, in `<dir>/orphans/` (`Aerotow.Orphans`):

      <dir>/orphans/<store>/<ref>.<flight>.gldb      with its siblings, marker and note

  which is where a lost flight puts its copy too (`Aerotow.Flight.Copy`).
  A copy whose marker cannot be read is named `<ref>.0.gldb`, and a name
  that is taken gets a number after it. Whatever else is under `flights/`
  goes to `<dir>/orphans/left-<unix ms>/`, as it was.

  As the instance starts, `at_start/1` (before its stores are made) sets
  aside the copies that can never be carried: no marker that can be read, no
  database, or a restore into it that never finished. What is left waits for
  `Aerotow.Recovery`, which decides on each against its store. `found/4` is
  the same decision for a copy a launch finds where its own copy would go.
  """

  require Logger

  alias Aerotow.{Clock, Instance, Orphans, Recovery, Ref, Store}
  alias Aerotow.Flight.Copy

  @doc """
  Sets aside, before any store is asked, the copies under `<dir>/flights/`
  that can never be carried, and keeps the files there that belong to no
  copy under `orphans/left-<unix ms>/`. Copies of gliders aloft here (a
  server started again under living flights) are left alone, and so are
  the copies that may be carried.
  """
  @spec at_start(Instance.t()) :: :ok
  def at_start(%Instance{} = instance) do
    all = copies(instance)

    for path <- all, not flying?(instance, path) do
      case unfit(path) do
        nil -> :ok
        why -> set_aside(instance, path, why, carry: false)
      end
    end

    keep_strays(instance, all)
    tidy(instance)
  end

  @doc """
  What to do with a copy a launch of `ref` found at `path`: answers the
  intent to launch with. `{:carry, path}` when the copy's flight is still
  the newest in the store and the copy opens (R15); otherwise the copy is
  set aside and the answer is `:launch`.
  """
  @spec found(Instance.t(), Store.t(), Ref.t(), Path.t()) ::
          {:ok, Aerotow.Flight.intent()} | {:error, term()}
  def found(%Instance{} = instance, %Store{} = store, ref, path),
    do: Recovery.decide(instance, store, ref, path)

  @doc """
  Moves the copy at `path` (its database, siblings and marker) into
  `<dir>/orphans/`, named by the store, ref and flight its marker gives, and
  writes beside it why. `carry: false` marks a copy that can never be
  carried (`Aerotow.Orphans.note/4`).
  """
  @spec set_aside(Instance.t(), Path.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def set_aside(%Instance{dir: dir} = instance, path, why \\ "it was left behind", opts \\ []) do
    {store, ref, n} = whose(instance, path)
    to = free(Path.join([dir, "orphans", store, "#{ref}.#{n}"]))

    case Copy.move(path, to) do
      :ok ->
        _ = Orphans.note(instance, to, why, opts)

        :telemetry.execute([:aerotow, :flight, :orphaned], %{}, %{
          ref: ref,
          store: store,
          flight: n,
          path: to,
          reason: :left_behind,
          why: why
        })

        Logger.info("aerotow: a working copy of #{ref} was set aside at #{to}: #{why}")
        :ok

      {:error, reason} ->
        Logger.error("aerotow: a working copy at #{path} could not be set aside: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  The working copies under `<dir>/flights/`, flying here or not, each as
  the path of its database.
  """
  @spec copies(Instance.t()) :: [Path.t()]
  def copies(%Instance{dir: dir}) do
    flights = Path.join(dir, "flights")

    if File.dir?(flights) do
      flights
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.flat_map(fn path ->
        cond do
          String.contains?(path, [".gldb-", ".gldb/", ".gldb.restoring"]) ->
            []

          String.ends_with?(path, ".flight.json") ->
            [String.replace_suffix(path, ".flight.json", ".gldb")]

          String.ends_with?(path, ".gldb") ->
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

  @doc "Whether the copy at `path` is a glider flying here now."
  @spec flying?(Instance.t(), Path.t()) :: boolean()
  def flying?(%Instance{registry: registry} = instance, path) do
    {store, ref, _n} = whose(instance, path)

    registry != nil and Process.whereis(registry) != nil and
      match?([{_pid, ^store}], Registry.lookup(registry, ref))
  end

  @doc "Removes the directories left empty under `<dir>/flights/`, and it too when empty."
  @spec tidy(Instance.t()) :: :ok
  def tidy(%Instance{dir: dir}), do: Orphans.tidy(Path.join(dir, "flights"))

  # Why a copy can never be carried, or nil. What decides this is on disk.
  defp unfit(path) do
    case Copy.read_marker(path) do
      {:error, reason} -> "its marker cannot be read (#{reason})"
      {:ok, _marker} -> unfinished(path)
    end
  end

  defp unfinished(path) do
    cond do
      not match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) ->
        "it has no database: its flight stopped before it made one"

      File.exists?(path <> ".restoring") ->
        "a restore into it did not finish"

      true ->
        nil
    end
  end

  # The store, ref and flight a copy belongs to: from its marker, or from
  # where it is when the marker cannot be read.
  defp whose(%Instance{dir: dir}, path) do
    case Copy.read_marker(path) do
      {:ok, marker} ->
        {marker.store, marker.ref, marker.flight}

      {:error, _} ->
        relative =
          if String.starts_with?(path, Path.join(dir, "flights") <> "/"),
            do: Path.relative_to(path, Path.join(dir, "flights")),
            else: ""

        case String.split(relative, "/", parts: 2) do
          [store, rest] ->
            ref = String.replace_suffix(rest, ".gldb", "")
            if Ref.valid?(ref), do: {store, ref, 0}, else: {"unknown", "copy", 0}

          _ ->
            {"unknown", "copy", 0}
        end
    end
  end

  # `<base>.gldb`, or `<base>.<k>.gldb` for the first k that is free.
  defp free(base, k \\ 0) do
    path = if k == 0, do: base <> ".gldb", else: "#{base}.#{k}.gldb"
    if Copy.exists?(path), do: free(base, k + 1), else: path
  end

  # The files under flights/ that belong to no copy: kept, as they were,
  # beside the orphans.
  defp keep_strays(%Instance{dir: dir, clock: clock}, copies) do
    flights = Path.join(dir, "flights")
    owners = Enum.flat_map(copies, &[&1, String.replace_suffix(&1, ".gldb", ".flight.json")])

    strays =
      flights
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Enum.reject(fn file -> Enum.any?(owners, &String.starts_with?(file, &1)) end)

    if strays != [] do
      to = Path.join([dir, "orphans", "left-#{Clock.now(clock)}"])

      Enum.each(strays, fn file ->
        target = Path.join(to, Path.relative_to(file, flights))

        with :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- File.rename(file, target) do
          :ok
        else
          {:error, reason} ->
            Logger.error(
              "aerotow: #{file} is no working copy and could not be moved aside: " <>
                inspect(reason)
            )
        end
      end)

      Logger.warning(
        "aerotow: files under #{flights} that were no working copy were kept at #{to}"
      )
    end

    :ok
  end
end
