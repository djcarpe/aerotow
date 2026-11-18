defmodule Aerotow.Store.Peer do
  @moduledoc """
  A store that is another aerotow, reached over HTTP: the `peer` kind.

      {"west", "https://west.example.com/aerotow", token: token}

  A peer store holds nothing this instance reads as bytes; it answers
  questions, through the protocol `Aerotow.Plug` serves and
  `Aerotow.Wire` writes. Its cards come into the catalog with a scan
  (`list_cards/1` pages through the peer's `gliders` op), homed in this
  store, and a call for one of them is forwarded to the peer
  (`Aerotow.Forward`), which does its own launching.

  ## Options

    * `token:` (required) sent as `authorization: Bearer …` with every
      request. It is kept in a function in the config, so it is never shown
      by `inspect/1`, and it is never part of a reason or a log line (R4).
      A url with a `user:password@` in it is refused: the token is how a
      peer is given a credential.
    * `receive_timeout:` how long one request waits for its answer (60 s).
    * `attempts:` how many times a read is sent before its failure is the
      answer (3).
    * `max_answer:` the most bytes of an answer that are read (64 MiB);
      a longer one is a failure.

  ## Making one

  `init/3` asks the peer `GET <url>/v1` for its id and keeps it. Every
  answer after that must carry the same id in its `aerotow-id` header: a
  peer that answers as another aerotow (a url that now points somewhere
  else) is refused, not believed. A peer that cannot be asked as the store
  is made leaves the store unavailable, and the instance tries again later.

  ## Failures

  Each is `{:error, reason}` with a reason a person can read; `where` is
  the store's name:

    * the peer did not answer, timed out, answered something that is not
      an aerotow's answer, or answered as another aerotow:
      `{:peer_unavailable, where, reason}`
    * it refused the token: `{:peer_unavailable, where, reason}`, saying so
    * it answered an error: the reason it gave (`:not_found`,
      `{:aloft_elsewhere, holder}`, a statement refused, …), as
      `Aerotow.Wire.decode_error/1` reads it

  A read (`gliders`, `card`, `query`, `context`, `schema`, `stats`, `find`,
  `search`) that had no answer, or an answer with a 5xx status that was not
  an aerotow's error, is sent again, up to `attempts:` in all, 50 ms and
  then 100 ms apart. A write (`create`, `update`, `delete`, `run`,
  `batch`) is sent once. When a write's connection was refused it was not
  sent, and that is `{:peer_unavailable, …}`; when it was sent and no
  answer came back (a timeout, a closed connection, a 5xx from something
  in between) it may or may not have been applied, and that is
  `{:outcome_unknown, where, reason}` for the caller to settle, by reading
  before writing again.
  """

  alias Aerotow.{Card, Store, Wire}

  @receive_timeout 60_000
  @connect_timeout 5_000
  @attempts 3
  @backoff 50
  @max_answer 64 * 1024 * 1024
  @page 500
  @max_pages 2_000
  @format 1
  @id ~r/\A[0-9a-f]{32}\z/
  @memo {__MODULE__, :listed}

  # ------------------------------------------------------------------ init

  @doc """
  Checks the url and options and asks the peer for its id. Answers the
  store's config, or a reason that never holds the token.
  """
  @spec init(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def init(name, url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, base} <- base(url),
         {:ok, token} <- token(Keyword.get(opts, :token)),
         {:ok, receive_timeout} <- positive(opts, :receive_timeout, @receive_timeout),
         {:ok, attempts} <- positive(opts, :attempts, @attempts),
         {:ok, max_answer} <- positive(opts, :max_answer, @max_answer) do
      config = %{
        name: name,
        base: base,
        token: fn -> token end,
        receive_timeout: receive_timeout,
        attempts: attempts,
        max_answer: max_answer,
        id: nil
      }

      with {:ok, id} <- hello(config), do: {:ok, %{config | id: id}}
    end
  end

  defp base(url) do
    case URI.parse(url) do
      %URI{userinfo: info} when is_binary(info) ->
        {:error, "a peer's url has no user or password in it; give the peer token: instead"}

      %URI{scheme: scheme, host: host, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        {:error, "a peer's url is http(s)://host/path, with no query or fragment"}
    end
  end

  defp token(token) when is_binary(token) and token != "" do
    if String.valid?(token) and not String.match?(token, ~r/[\x00-\x20\x7F]/),
      do: {:ok, token},
      else: {:error, "a peer's token is text with no spaces or control characters"}
  end

  defp token(nil), do: {:error, "a peer store needs token:, which the peer's Aerotow.Plug takes"}
  defp token(_), do: {:error, "a peer's token is text"}

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, "#{key} is a positive integer, got: #{inspect(other)}"}
    end
  end

  # GET <base>/v1: the peer's id.
  defp hello(config) do
    case attempt(config, :get, config.base <> "/v1", nil, 0) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, %{"id" => id, "format" => @format}} when is_binary(id) ->
            if Regex.match?(@id, id),
              do: {:ok, id},
              else: {:error, "#{config.base}/v1 did not answer an aerotow's id"}

          {:ok, %{"format" => other}} ->
            {:error, "the peer speaks format #{inspect(other)}; this aerotow speaks #{@format}"}

          _ ->
            {:error, "#{config.base}/v1 did not answer as an aerotow"}
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, "the peer at #{config.base} refused the token (#{status})"}

      {:ok, %{status: status}} ->
        {:error, "the peer at #{config.base} answered #{status}"}

      {:error, {_sent, why}} ->
        {:error, "the peer at #{config.base}: #{why}"}
    end
  end

  # ------------------------------------------------------------------ calls

  @doc """
  Sends a request (`Aerotow.Wire`) to the peer as hop `hop`, and answers
  what the peer answered, as the terms a local call gives.
  """
  @spec call(Store.t(), Wire.request(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def call(%Store{name: name, config: %{base: _} = config}, request, hop) do
    op = elem(request, 0)

    with {:ok, segment, body} <- Wire.encode_request(request) do
      url = config.base <> "/v1/" <> segment
      json = JSON.encode!(body)
      tries = if Wire.read?(op), do: config.attempts, else: 1
      send_request(config, name, op, url, json, hop, tries, 1)
    end
  end

  def call(%Store{name: name}, _request, _hop),
    do: {:error, {:peer_unavailable, name, "the store was not made as a peer"}}

  defp send_request(config, name, op, url, json, hop, tries, n) do
    result = attempt(config, :post, url, json, hop)

    case judge(config, name, op, result) do
      {:retry, _why} when n < tries ->
        Process.sleep(@backoff * Integer.pow(2, n - 1))
        send_request(config, name, op, url, json, hop, tries, n + 1)

      {:retry, why} ->
        failed(name, op, why, sent?(result))

      answer ->
        answer
    end
  end

  defp sent?({:error, {sent, _why}}), do: sent
  defp sent?({:ok, _}), do: true

  defp failed(name, op, why, sent?) do
    if Wire.read?(op) or not sent?,
      do: {:error, {:peer_unavailable, name, why}},
      else:
        {:error, {:outcome_unknown, name, why <> "; the write may or may not have been applied"}}
  end

  defp judge(_config, _name, _op, {:error, {_sent, why}}), do: {:retry, why}

  defp judge(config, name, op, {:ok, %{status: status, body: body, id: id}}) do
    cond do
      id != nil and id != config.id ->
        {:error,
         {:peer_unavailable, name,
          "it answered as the aerotow #{id}, not #{config.id} it was when the store was made"}}

      status in [401, 403] ->
        {:error, {:peer_unavailable, name, "it refused this aerotow's token (#{status})"}}

      status == 200 and id == nil ->
        {:error, {:peer_unavailable, name, "it answered without an aerotow's id"}}

      status == 200 ->
        case decode(body) do
          {:ok, json} ->
            case Wire.decode_answer(op, json, name) do
              {:ok, value} -> {:ok, value}
              {:error, why} -> {:error, {:peer_unavailable, name, why}}
            end

          :error ->
            {:error, {:peer_unavailable, name, "its answer is not JSON"}}
        end

      true ->
        with {:ok, json} <- decode(body),
             {:ok, reason} <- Wire.decode_error(json) do
          {:error, reason}
        else
          _ when status >= 500 -> {:retry, "it answered #{status}"}
          _ -> failed(name, op, "it answered #{status}", status != 404)
        end
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> :error
    end
  end

  # One request. `{:ok, %{status, body, id}}`, or `{:error, {sent?, why}}`
  # where `sent?` says whether the request may have reached the peer.
  defp attempt(config, method, url, body, hop) do
    headers =
      [{"authorization", "Bearer " <> config.token.()}, {"accept", "application/json"}] ++
        if(body, do: [{"content-type", "application/json"}, {"aerotow-hops", "#{hop}"}], else: [])

    max = config.max_answer

    request = [
      method: method,
      url: url,
      headers: headers,
      body: body || "",
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      cache: false,
      receive_timeout: config.receive_timeout,
      connect_options: [timeout: @connect_timeout],
      into: fn {:data, data}, {req, resp} ->
        {size, chunks} = Req.Response.get_private(resp, :aerotow_body, {0, []})
        size = size + byte_size(data)
        resp = Req.Response.put_private(resp, :aerotow_body, {size, [data | chunks]})
        if size > max, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
      end
    ]

    try do
      case Req.request(request) do
        {:ok, %Req.Response{} = resp} ->
          {size, chunks} = Req.Response.get_private(resp, :aerotow_body, {0, []})

          if size > max do
            {:error, {true, "its answer is longer than #{max} bytes"}}
          else
            {:ok,
             %{
               status: resp.status,
               body: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
               id: id_header(resp)
             }}
          end

        {:error, exception} ->
          transport(exception, config)
      end
    rescue
      exception -> transport(exception, config)
    end
  end

  defp id_header(resp) do
    case Req.Response.get_header(resp, "aerotow-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  # Only what an exception says about the connection, never the request
  # (whose headers hold the token).
  defp transport(%{reason: :timeout}, config),
    do: {:error, {true, "it did not answer within #{config.receive_timeout} ms"}}

  defp transport(%{reason: reason}, _config)
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach],
       do: {:error, {false, "it could not be reached (#{reason})"}}

  defp transport(%module{} = exception, _config)
       when module in [Req.TransportError, Mint.TransportError, Mint.HTTPError, Finch.Error],
       do: {:error, {true, "the connection failed: " <> Exception.message(exception)}}

  defp transport(%module{}, _config),
    do: {:error, {true, "the request failed (#{inspect(module)})"}}

  # ------------------------------------------------------------------ cards

  @doc """
  Every glider the peer lists in its `gliders` op, page by page, with a
  version that changes when the card does. The cards listed are kept in the
  calling process for `read_card/2` to take, so a scan reads each page once
  and not each card again.
  """
  @spec list_cards(Store.t()) ::
          {:ok, [%{ref: String.t(), version: String.t()}]} | {:error, String.t()}
  def list_cards(%Store{} = store) do
    case pages(store, nil, 0, []) do
      {:ok, cards} ->
        Process.put({@memo, store.name}, Map.new(cards, &{&1.ref, &1}))
        {:ok, cards |> Enum.map(&%{ref: &1.ref, version: version(&1)}) |> Enum.sort_by(& &1.ref)}

      {:error, reason} ->
        {:error, text(reason)}
    end
  end

  defp pages(_store, _after, @max_pages, _acc),
    do: {:error, "the peer listed more than #{@max_pages} pages"}

  defp pages(store, after_ref, n, acc) do
    request = {:gliders, Enum.reject([after: after_ref, limit: @page], &is_nil(elem(&1, 1)))}

    case call(store, request, hop()) do
      {:ok, %{gliders: cards, next: nil}} ->
        {:ok, Enum.reverse(acc, cards)}

      {:ok, %{gliders: cards, next: next}} when next != after_ref ->
        pages(store, next, n + 1, Enum.reverse(cards, acc))

      {:ok, _} ->
        {:error, "the peer's pages do not move on"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp version(card) do
    :sha256
    |> :crypto.hash(Card.encode(card))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  @doc """
  A glider's card, as the peer has it: the one the last `list_cards/1` in
  this process listed, or else asked for with the `card` op.
  """
  @spec read_card(Store.t(), String.t()) :: {:ok, Card.t()} | {:error, :not_found | String.t()}
  def read_card(%Store{} = store, ref) do
    listed = Process.get({@memo, store.name}, %{})

    case Map.pop(listed, ref) do
      {%Card{} = card, rest} ->
        Process.put({@memo, store.name}, rest)
        {:ok, card}

      {nil, _} ->
        case call(store, {:card, ref}, hop()) do
          {:ok, card} -> {:ok, card}
          {:error, :not_found} -> {:error, :not_found}
          {:error, reason} -> {:error, text(reason)}
        end
    end
  end

  # The hop a card's lookup goes out as: as any forward from this process.
  defp hop do
    case Aerotow.Forward.next_hop() do
      {:ok, hop} -> hop
      {:error, :too_many_hops} -> Aerotow.Forward.max_hops() + 1
    end
  end

  defp text(reason) when is_binary(reason), do: reason
  defp text({:peer_unavailable, name, why}), do: "peer #{name}: #{why}"
  defp text(reason), do: inspect(reason)
end
