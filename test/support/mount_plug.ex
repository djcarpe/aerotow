defmodule Aerotow.MountPlug do
  @moduledoc """
  `Aerotow.Plug` mounted under a path, as a Phoenix or Plug router's
  `forward "/aerotow", Aerotow.Plug, …` mounts it: the first segment of the
  path is the mount, and the plug sees the rest.
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    {mount, opts} = Keyword.pop(opts, :mount, "aerotow")
    {mount, Aerotow.Plug.init(opts)}
  end

  @impl true
  def call(%Plug.Conn{path_info: [mount | rest]} = conn, {mount, opts}),
    do: Plug.forward(conn, rest, Aerotow.Plug, opts)

  def call(conn, _), do: Plug.Conn.send_resp(conn, 404, "nothing is mounted here")
end
