defmodule Aerotow.Supervisor do
  @moduledoc """
  One running aerotow: its processes, under one supervisor registered as
  the instance's name.

      Aerotow.Supervisor (registered as name:)
      ├─ Registry              flights by ref
      ├─ Aerotow.Catalog       owns <dir>/catalog.gldb; the only writer of it
      ├─ Task.Supervisor       shipping passes, scans, landings for room
      ├─ DynamicSupervisor     one Aerotow.Flight per glider aloft here
      ├─ Aerotow.Server        stores and their credentials, the instance id,
      │                        eviction, the scan timer
      └─ Aerotow.Flight.Slots  shipping passes running at once, VM-wide

  The catalog starts before anything touches the directory: its file's lock
  is what makes one instance per `dir`, in this VM or another. The server
  starts last, after the processes it uses, and makes the instance findable
  (`Aerotow.Instance.put/1`) as the last thing it does, so nothing calls in
  before everything is there.

  The strategy is `:rest_for_one`. A server that dies is started again with
  the flights left flying; a catalog that dies takes the flights and the
  server with it, and the server that starts again finds their working
  copies on disk (`Aerotow.Copies.at_start/1`).

  `Aerotow.Flight.Slots` is one process for the whole VM. The first instance
  to start runs it; in any other instance its child is ignored, and should
  the first one stop, the next shipping pass starts it again on its own.
  """

  use Supervisor

  alias Aerotow.{Catalog, Instance, Options}

  @doc "Starts an instance from options that `Aerotow.Options.check/1` has accepted."
  @spec start_link(Options.t()) :: Supervisor.on_start()
  def start_link(%{name: name} = config),
    do: Supervisor.start_link(__MODULE__, config, name: name)

  @impl true
  def init(config) do
    names = Instance.names(config.name)

    children = [
      {Registry, keys: :unique, name: names.registry},
      {Catalog, path: Path.join(config.dir, "catalog.gldb"), name: names.catalog},
      {Task.Supervisor, name: names.tasks},
      {DynamicSupervisor, name: names.flights, strategy: :one_for_one},
      Supervisor.child_spec({Aerotow.Server, config}, shutdown: Aerotow.Server.shutdown()),
      %{id: Aerotow.Flight.Slots, start: {__MODULE__, :start_slots, []}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  # The keeper of slots is one per VM: started here unless it already runs.
  @spec start_slots() :: {:ok, pid()} | :ignore | {:error, term()}
  def start_slots do
    case Aerotow.Flight.Slots.start_link() do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end
end
