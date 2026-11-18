defmodule Aerotow.Copies do
  @moduledoc """
  Working copies found on disk that no flight here is flying.

  A copy under `<dir>/flights/` belongs to a flight that ran here and did not
  land: the instance stopped, or its catalog died and took the flights with
  it. Such a copy may hold log that never shipped, so it is never deleted.
  For now it is set aside, whole, in `<dir>/orphans/`:

      <dir>/orphans/<store>/<ref>.<flight>.gldb      with its siblings and marker

  which is where a lost flight puts its copy too (`Aerotow.Flight.Copy`).
  A copy whose marker cannot be read is named `<ref>.0.gldb`, and a name
  that is taken gets a number after it. Whatever else is under `flights/`
  goes to `<dir>/orphans/left-<unix ms>/` as it was.

  Two functions are where carrying a copy into the next flight (R15) plugs
  in, which the recovery slice adds: `at_start/1`, called once as the
  instance starts and before its first launch, and `found/4`, called when a
  launch finds a copy where its own would go. Today both set the copy
  aside, and `found/4` answers that the launch should go ahead.
  """

  require Logger

  alias Aerotow.{Clock, Instance, Ref, Store}
  alias Aerotow.Flight.Copy

  @doc """
  Sets aside every copy under `<dir>/flights/` whose glider has no flight
  here. Copies of gliders aloft here (a server started again under living
  flights) are left alone.
  """
  @spec at_start(Instance.t()) :: :ok
  def at_start(%Instance{dir: dir} = instance) do
    flights = Path.join(dir, "flights")

    {flying, left} = flights |> copies() |> Enum.split_with(&flying?(instance, &1))
    Enum.each(left, &set_aside(instance, &1))

    # With flights still flying, what is under flights/ is theirs.
    if flying == [], do: sweep(instance, flights)
    :ok
  end

  @doc """
  What to do with a copy a launch of `ref` found at `path`: answers the
  intent to launch with. Today the copy is set aside and the answer is
  `:launch`; the recovery slice answers `{:carry, path}` when the copy's
  flight is still the newest.
  """
  @spec found(Instance.t(), Store.t(), Ref.t(), Path.t()) ::
          {:ok, Aerotow.Flight.intent()} | {:error, String.t()}
  def found(%Instance{} = instance, %Store{}, _ref, path) do
    case set_aside(instance, path) do
      :ok -> {:ok, :launch}
      {:error, _} = error -> error
    end
  end

  @doc """
  Moves the copy at `path` (its database, siblings and marker) into
  `<dir>/orphans/`, named by the store, ref and flight its marker gives.
  """
  @spec set_aside(Instance.t(), Path.t()) :: :ok | {:error, String.t()}
  def set_aside(%Instance{dir: dir} = instance, path) do
    {store, ref, n} = whose(instance, path)
    to = free(Path.join([dir, "orphans", store, "#{ref}.#{n}"]))

    case Copy.move(path, to) do
      :ok ->
        :telemetry.execute([:aerotow, :flight, :orphaned], %{}, %{
          ref: ref,
          store: store,
          flight: n,
          path: to,
          reason: :left_behind
        })

        Logger.info("aerotow: a working copy of #{ref} left behind was set aside at #{to}")
        :ok

      {:error, reason} ->
        Logger.error("aerotow: a working copy at #{path} could not be set aside: #{reason}")
        {:error, reason}
    end
  end

  # The databases and markers under flights/, each as the path of its
  # database. What is inside glider's own directories beside a database is
  # not a copy.
  defp copies(flights) do
    if File.dir?(flights) do
      flights
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.flat_map(fn path ->
        cond do
          String.contains?(path, [".gldb-", ".gldb/"]) ->
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

  defp flying?(%Instance{registry: registry} = instance, path) do
    {store, ref, _n} = whose(instance, path)

    registry != nil and Process.whereis(registry) != nil and
      match?([{_pid, ^store}], Registry.lookup(registry, ref))
  end

  # The store, ref and flight a copy belongs to: from its marker, or from
  # where it is when the marker cannot be read.
  defp whose(%Instance{dir: dir}, path) do
    case Copy.read_marker(path) do
      {:ok, marker} ->
        {marker.store, marker.ref, marker.flight}

      {:error, _} ->
        relative = Path.relative_to(path, Path.join(dir, "flights"))

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

  # What is left under flights/ that is no copy: kept, as it was, beside
  # the orphans. Empty directories go.
  defp sweep(%Instance{dir: dir, clock: clock}, flights) do
    case files(flights) do
      [] ->
        _ = File.rm_rf(flights)
        :ok

      _left ->
        to = Path.join([dir, "orphans", "left-#{Clock.now(clock)}"])

        with :ok <- File.mkdir_p(Path.dirname(to)),
             :ok <- File.rename(flights, to) do
          Logger.warning(
            "aerotow: files under #{flights} that were no working copy were kept at #{to}"
          )
        else
          {:error, reason} ->
            Logger.error(
              "aerotow: #{flights} holds files that could not be moved aside: #{inspect(reason)}"
            )
        end
    end
  end

  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
  end
end
