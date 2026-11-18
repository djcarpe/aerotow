defmodule Aerotow.PeerCase do
  @moduledoc """
  What the peer slice's tests share: an aerotow served over HTTP on
  `127.0.0.1` with Bandit, servers that answer as a test says, and a second
  node for forwarding over distribution.
  """

  import ExUnit.Callbacks

  @token "peer-token-0f3a9c"

  @doc "The token the servers started here take."
  @spec token() :: String.t()
  def token, do: @token

  @doc """
  Serves `tow` with `Aerotow.Plug` mounted at `/aerotow`, and answers the
  base url, `http://127.0.0.1:<port>/aerotow`. `opts` are the plug's
  (`tokens: [token()]` unless given) and `id:` for the server's child id.
  """
  @spec serve(atom(), keyword()) :: String.t()
  def serve(tow, opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id, make_ref())
    opts = Keyword.merge([tow: tow, tokens: [@token]], opts)
    port = listen({Aerotow.MountPlug, opts}, id)
    "http://127.0.0.1:#{port}/aerotow"
  end

  @doc "Serves `fun` (a function of the conn) as `Aerotow.StubPlug`, and answers its base url."
  @spec stub((Plug.Conn.t() -> Plug.Conn.t()), term()) :: String.t()
  def stub(fun, id \\ make_ref()) do
    port = listen({Aerotow.StubPlug, fun}, id)
    "http://127.0.0.1:#{port}/aerotow"
  end

  defp listen(plug, id) do
    server =
      start_supervised!(
        {Bandit,
         plug: plug,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 1_000]},
        id: id
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc "A JSON answer from a stub, with an `aerotow-id` header when `id` is given."
  @spec json(Plug.Conn.t(), pos_integer(), term(), String.t() | nil) :: Plug.Conn.t()
  def json(conn, status, body, id \\ nil) do
    conn = if id, do: Plug.Conn.put_resp_header(conn, "aerotow-id", id), else: conn

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  @doc "A stub's answer to `GET /v1`, as the aerotow `id`."
  @spec hello(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def hello(conn, id), do: json(conn, 200, %{"aerotow" => "0.1.0", "id" => id, "format" => 1}, id)

  @doc """
  Makes this VM a distributed node, if it is not one, until the test ends.
  """
  @spec distributed!() :: node()
  def distributed! do
    unless Node.alive?() do
      name = :"aerotow_test_#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
      on_exit(fn -> :net_kernel.stop() end)
    end

    node()
  end

  @doc """
  Starts a second node with this VM's code paths and cookie, and answers its
  name. It is stopped when the test ends.
  """
  @spec peer_node!(String.t()) :: node()
  def peer_node!(label) do
    distributed!()
    name = :"#{label}_#{System.unique_integer([:positive])}"
    cookie = Node.get_cookie() |> Atom.to_charlist()

    {:ok, pid, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", cookie]
      })

    on_exit(fn -> :peer.stop(pid) end)
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    node
  end
end
