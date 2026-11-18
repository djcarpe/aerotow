if Code.ensure_loaded?(Plug) do
  defmodule Aerotow.Plug do
    @moduledoc """
    The HTTP surface of an aerotow, which another aerotow's `peer` store
    talks to:

        forward "/aerotow", Aerotow.Plug, tow: MyApp.Aerotow, tokens: [token]

    Statements that arrive here are untrusted input. The glider aerotow pins
    (djcarpe/glider `7aed281`, with its `fix/bounded-depth`) refuses one nested
    deeper than 64 levels with an error instead of overflowing the stack, so a
    `run` sent with a token cannot take the VM down. An older glider could.

    `:plug` is an optional dependency of aerotow: this module exists only
    when Plug is there, and nothing else in aerotow needs it.

    ## Protocol

    `GET <base>/v1` answers `{"aerotow": version, "id": id, "format": 1}`.
    Every op is `POST <base>/v1/<op>` with a JSON object for a body, as
    `Aerotow.Wire` reads it, answered with JSON and status 200. Every answer
    carries the instance's id in an `aerotow-id` header, so a client can
    tell the aerotow it is talking to has not changed. A forwarded call
    says which hop it is in an `aerotow-hops` header (1 when there is
    none); see `Aerotow.Forward`.

    Errors are `{"error": message, "code": code}`, with these statuses:

    | status | code | when |
    |---|---|---|
    | 400 | `bad_request` | a body that is not a JSON object, or not a request of its op |
    | 401 | `unauthorized` | no token, or one that is not taken (with `tokens:`) |
    | 403 | `forbidden` | `authorize` said no (or the status it gave) |
    | 404 | `unknown_op` | a path that is no op |
    | 404 | `not_found` | no glider of that ref |
    | 405 | `method_not_allowed` | `GET` of an op, or anything but `GET` of `/v1` |
    | 409 | `exists`, `aloft_elsewhere`, `runs_on_peer`, `purging` | as the reasons of those names |
    | 413 | `too_large` | a body over `max_body` |
    | 422 | `refused` | a statement or an option the instance refused, or glider's own error |
    | 500 | `error` | anything else |
    | 503 | `store_unavailable`, `peer_unavailable`, `outcome_unknown`, `unavailable` | the instance or what it needs cannot answer now |
    | 504 | `timeout` | the call timed out |
    | 508 | `too_many_hops` | the call was forwarded more than three times |

    Unknown ops, wrong methods, bodies that are not JSON objects and bodies
    over `max_body` are refused before anything runs.

    ## Options

      * `tow:` (required) the instance's name.
      * `tokens:` a list of tokens. A request must carry one as
        `authorization: Bearer …`; it is compared with each in constant
        time (`Plug.Crypto.secure_compare/2`), before the body is read.
      * `authorize:` a function of the conn and `%{op: op, ref: ref}`
        answering `:ok` or `{:error, status, message}`. `op` is the
        request's op (`:query`, `:write_batch`, …, and `:info` for
        `GET /v1`); `ref` the glider it is for, or `nil`. It needs the ref,
        which is in the body, so it is called once the body has been read
        and decoded, and before anything runs. With `tokens:` as well, the
        token is checked first.
      * `max_body:` the most bytes a body may have (8 MiB).
      * `max_rows:`, `max_bytes:` the most a query answers here, whatever
        it asks for (10,000 rows, 8 MiB), as `Aerotow.Forward.serve/4`
        bounds it.

    Without `tokens:` or `authorize:`, `init/1` raises: the plug does not
    start open. A token is never part of a log line, an answer or
    telemetry.

    ## Telemetry

    Each request is a span, `[:aerotow, :plug, :start | :stop |
    :exception]`, with `method` and `op` (the path segment, or `nil`), and
    when it stops `status` and `ref`.
    """

    @behaviour Plug

    import Plug.Conn

    alias Aerotow.{Forward, Instance, Wire}

    @max_body 8 * 1024 * 1024
    @format 1

    @impl true
    def init(opts) when is_list(opts) do
      tow = Keyword.get(opts, :tow)
      tokens = Keyword.get(opts, :tokens)
      authorize = Keyword.get(opts, :authorize)

      unless is_atom(tow) and tow not in [nil, true, false],
        do: raise(ArgumentError, "Aerotow.Plug needs tow:, the name of an aerotow instance")

      unless is_nil(tokens) or
               (is_list(tokens) and tokens != [] and
                  Enum.all?(tokens, &(is_binary(&1) and &1 != ""))),
             do: raise(ArgumentError, "tokens: is a list of non-empty strings")

      unless is_nil(authorize) or is_function(authorize, 2),
        do: raise(ArgumentError, "authorize: is a function of the conn and %{op:, ref:}")

      if is_nil(tokens) and is_nil(authorize),
        do:
          raise(
            ArgumentError,
            "Aerotow.Plug needs tokens: or authorize:; it does not answer without one"
          )

      %{
        tow: tow,
        # Behind a function, so the plug's options never show them.
        tokens: if(tokens, do: fn -> tokens end),
        authorize: authorize,
        max_body: positive(opts, :max_body, @max_body),
        limits: [
          max_rows: positive(opts, :max_rows, 10_000),
          max_bytes: positive(opts, :max_bytes, 8 * 1024 * 1024)
        ]
      }
    end

    defp positive(opts, key, default) do
      case Keyword.get(opts, key, default) do
        n when is_integer(n) and n > 0 -> n
        other -> raise ArgumentError, "#{key}: is a positive integer, got: #{inspect(other)}"
      end
    end

    @impl true
    def call(conn, config) do
      meta = %{method: conn.method, op: op_segment(conn.path_info)}

      :telemetry.span([:aerotow, :plug], meta, fn ->
        conn = conn |> put_private(:aerotow_ref, nil) |> handle(config)
        {conn, Map.merge(meta, %{status: conn.status, ref: conn.private[:aerotow_ref]})}
      end)
    end

    defp op_segment(["v1", op]), do: op
    defp op_segment(_), do: nil

    defp handle(conn, config) do
      case Instance.fetch(config.tow) do
        {:ok, instance} ->
          conn = put_resp_header(conn, "aerotow-id", instance.id)
          route(conn, config, instance)

        {:error, :not_running} ->
          refuse(conn, :not_running)
      end
    end

    defp route(%{method: method, path_info: ["v1"]} = conn, config, instance) do
      cond do
        method != "GET" -> fail(conn, 405, "method_not_allowed", "GET /v1, POST /v1/<op>")
        not token?(conn, config) -> unauthorized(conn)
        true -> info(conn, config, instance)
      end
    end

    defp route(%{method: method, path_info: ["v1", segment]} = conn, config, _instance) do
      case Wire.op(segment) do
        {:ok, op} when method == "POST" ->
          if token?(conn, config), do: post(conn, config, op), else: unauthorized(conn)

        {:ok, _op} ->
          fail(conn, 405, "method_not_allowed", "an op is POST /v1/#{segment}")

        :error ->
          fail(conn, 404, "unknown_op", "no op is called that (#{Enum.join(Wire.names(), ", ")})")
      end
    end

    defp route(conn, _config, _instance),
      do: fail(conn, 404, "unknown_op", "this is an aerotow: GET /v1, POST /v1/<op>")

    defp info(conn, config, instance) do
      case authorize(conn, config, :info, nil) do
        :ok ->
          version = :aerotow |> Application.spec(:vsn) |> to_string()
          answer(conn, 200, %{"aerotow" => version, "id" => instance.id, "format" => @format})

        {:error, status, message} ->
          fail(conn, status, "forbidden", message)
      end
    end

    defp post(conn, config, op) do
      with {:ok, hop} <- hop(conn),
           {:ok, body, conn} <- body(conn, config),
           {:ok, request} <- request(op, body),
           conn = put_private(conn, :aerotow_ref, Wire.ref(request)),
           :ok <- authorize(conn, config, op, Wire.ref(request)) do
        case Forward.serve(config.tow, request, hop, config.limits) do
          {:ok, value} -> encoded(conn, op, value)
          {:error, reason} -> refuse(conn, reason)
        end
      else
        {:fail, conn, status, code, message} -> fail(conn, status, code, message)
        {:fail, status, code, message} -> fail(conn, status, code, message)
        {:error, status, message} -> fail(conn, status, "forbidden", message)
      end
    end

    defp hop(conn) do
      case get_req_header(conn, "aerotow-hops") do
        [] ->
          {:ok, 1}

        [text | _] ->
          case Integer.parse(text) do
            {n, ""} when n >= 0 and n < 1_000 -> {:ok, n}
            _ -> {:fail, 400, "bad_request", "aerotow-hops is a whole number"}
          end
      end
    end

    defp body(conn, config) do
      max = config.max_body

      declared =
        case get_req_header(conn, "content-length") do
          [length | _] ->
            case Integer.parse(length) do
              {n, ""} -> n
              _ -> 0
            end

          [] ->
            0
        end

      if declared > max do
        {:fail, conn, 413, "too_large", "a body is at most #{max} bytes"}
      else
        case read_body(conn, length: max, read_length: min(max, 1_000_000)) do
          {:ok, body, conn} ->
            case JSON.decode(body) do
              {:ok, %{} = json} -> {:ok, json, conn}
              _ -> {:fail, conn, 400, "bad_request", "a body is a JSON object"}
            end

          {:more, _partial, conn} ->
            {:fail, conn, 413, "too_large", "a body is at most #{max} bytes"}

          {:error, _} ->
            {:fail, conn, 400, "bad_request", "the body could not be read"}
        end
      end
    end

    defp request(op, body) do
      case Wire.decode_request(op, body) do
        {:ok, request} -> {:ok, request}
        {:error, message} -> {:fail, 400, "bad_request", message}
      end
    end

    defp token?(_conn, %{tokens: nil}), do: true

    defp token?(conn, %{tokens: tokens}) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> given | _] ->
          # Each token is compared, whichever matches, so the time taken
          # says nothing of which one did.
          Enum.reduce(tokens.(), false, fn token, found ->
            Plug.Crypto.secure_compare(token, given) or found
          end)

        _ ->
          false
      end
    end

    defp authorize(_conn, %{authorize: nil}, _op, _ref), do: :ok

    defp authorize(conn, %{authorize: fun}, op, ref) do
      case fun.(conn, %{op: op, ref: ref}) do
        :ok ->
          :ok

        {:error, status, message} when is_integer(status) and status in 400..599 ->
          {:error, status, to_string(message)}

        _ ->
          {:error, 403, "not authorized"}
      end
    end

    defp unauthorized(conn) do
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> fail(401, "unauthorized", "a token is needed: authorization: Bearer …")
    end

    defp refuse(conn, reason) do
      {status, body} = Wire.encode_error(reason)
      answer(conn, status, body)
    end

    defp fail(conn, status, code, message),
      do: answer(conn, status, %{"error" => message, "code" => code})

    defp encoded(conn, op, value) do
      answer(conn, 200, Wire.encode_answer(op, value))
    rescue
      e in [ArgumentError, ErlangError, FunctionClauseError] ->
        fail(
          conn,
          500,
          "error",
          "the answer could not be written as JSON: " <> Exception.message(e)
        )
    end

    defp answer(conn, status, body) do
      json = JSON.encode!(body)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, json)
    end
  end
end
