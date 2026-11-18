defmodule Aerotow.Store.S3 do
  @moduledoc """
  An object store in an S3 bucket: the store `s3://graphs/gliders` keeps the
  object `cards/a/b.json` at the key `gliders/cards/a/b.json` of the bucket
  `graphs`. Anything that speaks S3 will do: AWS, MinIO, Ceph, SeaweedFS,
  Garage.

  Two clients use the same bucket. This module, over Req, reads and writes
  cards, flight records and listings. Glider's own client, inside its NIF,
  ships and restores replicas, given the url and options `replica/2` returns.

  ## Options

    * `endpoint:` where the bucket is served, `http://host[:port]` or
      `https://…`, for anything that is not AWS. Without it, AWS's own
      endpoint for the region.
    * `region:` (default `"us-east-1"`).
    * `access_key_id:` and `secret_access_key:`, which default to
      `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in the environment. A
      store with neither is refused by `init/3`.
    * `path_style:` whether the bucket is in the path (`/bucket/key`) or the
      host name (`bucket.host`). Default `true` with an `endpoint:`, `false`
      without.
    * `receive_timeout:` how long one request waits for an answer (default
      15 s).
    * `timeout:` the most one operation takes, all its requests and retries
      together (default 60 s; see "Time").

  ## Requests

  Requests are signed with SigV4 by Req. A key is sent as S3 signs it: every
  byte but `A-Z a-z 0-9 - . _ ~` and `/` percent-encoded, so a key with `+`,
  a space or `%` in it means the same to the signature, the server and this
  module. Listing answers are XML, read with `:xmerl_sax_parser`, which makes
  no atoms of what the server sent, refuses entity declarations and fetches
  nothing; the entities S3 escapes keys with (`&amp;`, `&lt;`, …) are
  decoded.

  A listing follows continuation tokens to the end, and a common prefix that
  arrives on two pages is given once. A key in the bucket that this store
  could not address (`Aerotow.Store.check_key/1` refuses it) is left out of
  listings.

  Versions are ETags, which change with an object's content.

  ## Retries

  A get, a listing, a delete, a plain put and the `HEAD` that settles an
  exclusive put are retried, up to three attempts in all, when the bucket
  does not answer, answers 500, 502, 503, 504 or 429, or the connection
  fails. Nothing is retried after another answer: 403, 404 and the like are
  the answer.

  ## Exclusive puts

  `put(…, exclusive: true)` is a `PUT` with `If-None-Match: *`, and carries a
  token of its own in `x-amz-meta-aerotow-put`.

    * 200: written, `:ok`.
    * 412: something is there, `{:error, :exists}`.
    * 409 (`ConditionalRequestConflict`, AWS's answer to a conditional put
      that raced another write of the same key): this put was not written.
      The key is looked at with `HEAD`: if something is there, it is
      `{:error, :exists}`; if not, the put is tried again.
    * No answer, or a 5xx: the put may or may not have been written, and
      trying it again blind could answer `:exists` for the object this very
      call wrote. So the key is looked at with `HEAD`. An object carrying this
      put's token is this put's, `:ok`; any other object is somebody else's,
      `{:error, :exists}`; no object means it was not written, and the put is
      tried again with the same token. A 412 that answers such a retry is
      settled the same way, since the first attempt may have landed in
      between. When the `HEAD` cannot be answered either, the result is an
      error saying that whether the object was written is not known.
    * 501 `NotImplemented`: the bucket has no conditional writes, an error
      (and `probe/1` says `cas: false`).

  ## Time

  Every operation returns within `timeout:` (60 s by default), whatever the
  bucket does: each request runs in a process of its own that is killed when
  its time is up, and no retry starts once the time is spent. A single
  request is given at most 5 s to connect and `receive_timeout:` to answer.
  With the defaults, three attempts at 20 s each fit in 60 s; between
  attempts the caller waits 50 ms, then 100 ms. A listing's pages share one
  operation's time.

  ## Credentials

  The keys are held in a function in the config, so neither `inspect/1` of
  the config nor of the store shows them, and they are never part of a
  reason or a log line (R4). `replica/2` has to hand them to glider, which
  takes them as options.

  ## What glider can do here

  Glider's client speaks plaintext HTTP and path-style only. With an
  `http://` endpoint it talks to the bucket itself; with an `https://` one,
  or none, it shells out to the `aws` CLI, which must then be on `PATH` and
  find the bucket by itself. Aerotow's own requests speak TLS through Req.
  """

  @behaviour Aerotow.Store.Objects

  alias Aerotow.Store

  @attempts 3
  @backoff 50
  @connect_timeout 5_000
  @receive_timeout 15_000
  @timeout 60_000
  @retry_statuses [429, 500, 502, 503, 504]
  @token_header "x-amz-meta-aerotow-put"
  @region ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @bucket ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
  @ipv4 ~r/\A\d{1,3}(\.\d{1,3}){3}\z/

  # ------------------------------------------------------------------ init

  @impl true
  def init(_name, url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, bucket, prefix} <- parse_url(url),
         {:ok, region} <- region(Keyword.get(opts, :region, "us-east-1")),
         {:ok, endpoint} <- endpoint(Keyword.get(opts, :endpoint)),
         {:ok, path_style} <- path_style(Keyword.get(opts, :path_style, endpoint != nil)),
         {:ok, receive_timeout} <-
           positive(opts, :receive_timeout, @receive_timeout),
         {:ok, timeout} <- positive(opts, :timeout, @timeout),
         {:ok, id} <- credential(opts, :access_key_id, "AWS_ACCESS_KEY_ID"),
         {:ok, secret} <- credential(opts, :secret_access_key, "AWS_SECRET_ACCESS_KEY") do
      {:ok,
       %{
         bucket: bucket,
         prefix: prefix,
         region: region,
         endpoint: endpoint,
         path_style: path_style,
         base: base(endpoint, bucket, region, path_style),
         receive_timeout: receive_timeout,
         timeout: timeout,
         credentials: fn -> {id, secret} end
       }}
    end
  end

  def init(_name, _url, _opts), do: {:error, "an s3 store's url is s3://bucket[/prefix]"}

  defp parse_url("s3://" <> rest) do
    {bucket, prefix} =
      case :binary.split(rest, "/") do
        [bucket] -> {bucket, ""}
        [bucket, prefix] -> {bucket, String.trim_trailing(prefix, "/")}
      end

    cond do
      String.contains?(rest, ["?", "#"]) ->
        {:error, "an s3 store's url is s3://bucket[/prefix], with no query or fragment"}

      String.contains?(bucket, "@") ->
        {:error,
         "an s3 store's url holds no credentials: give access_key_id: and secret_access_key:"}

      not bucket?(bucket) ->
        {:error,
         "not a bucket name: #{inspect(bucket)} (3 to 63 lower-case letters, digits, '.' " <>
           "and '-', starting and ending with a letter or digit)"}

      prefix == "" ->
        {:ok, bucket, ""}

      true ->
        case Store.check_key(prefix) do
          :ok -> {:ok, bucket, prefix}
          {:error, reason} -> {:error, "not a prefix in a bucket: " <> reason}
        end
    end
  end

  defp parse_url(_), do: {:error, "an s3 store's url is s3://bucket[/prefix]"}

  defp bucket?(name) do
    Regex.match?(@bucket, name) and not Regex.match?(@ipv4, name) and
      not String.contains?(name, ["..", ".-", "-."]) and
      not String.starts_with?(name, "xn--") and not String.ends_with?(name, "-s3alias")
  end

  defp region(region) when is_binary(region) do
    if Regex.match?(@region, region),
      do: {:ok, region},
      else: {:error, "not a region: #{inspect(region)}"}
  end

  defp region(other), do: {:error, "region is a string, got: #{inspect(other)}"}

  defp endpoint(nil), do: {:ok, nil}

  defp endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _ ->
        {:error,
         "an endpoint is http://host[:port] or https://host[:port], with no path, " <>
           "query or credentials"}
    end
  end

  defp endpoint(_), do: {:error, "endpoint is a string, http://host[:port]"}

  defp path_style(flag) when is_boolean(flag), do: {:ok, flag}
  defp path_style(other), do: {:error, "path_style is true or false, got: #{inspect(other)}"}

  defp positive(opts, name, default) do
    case Keyword.get(opts, name, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, "#{name} is a positive number of milliseconds, got: #{inspect(other)}"}
    end
  end

  # Neither value is ever repeated in a reason.
  defp credential(opts, name, env) do
    case Keyword.get(opts, name) || System.get_env(env) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, "no #{name}: give #{name}: or set #{env}"}
      _ -> {:error, "#{name} is a non-empty string"}
    end
  end

  defp base(nil, bucket, region, false), do: "https://#{bucket}.s3.#{region}.amazonaws.com"
  defp base(nil, _bucket, region, true), do: "https://s3.#{region}.amazonaws.com"
  defp base(endpoint, _bucket, _region, true), do: endpoint

  defp base(endpoint, bucket, _region, false) do
    uri = URI.parse(endpoint)
    URI.to_string(%{uri | host: bucket <> "." <> uri.host})
  end

  # ------------------------------------------------------------------ reading

  @impl true
  def get(config, key) do
    with :ok <- check_key(key) do
      deadline = deadline(config)

      case call(config, :get, key, [], deadline) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: 404} = response} ->
          missing(config, response, "GET", key, {:error, :not_found})

        other ->
          failed(config, other, "GET", key)
      end
    end
  end

  # A 404 is the key's absence, unless it is the bucket's.
  defp missing(config, response, method, key, absent) do
    case error_code(response) do
      {"NoSuchBucket", _} -> {:error, no_bucket(config, method, key)}
      _ -> absent
    end
  end

  # ------------------------------------------------------------------ writing

  @impl true
  def put(config, key, body, opts) do
    with :ok <- check_key(key),
         :ok <- check_body(body) do
      body = IO.iodata_to_binary(body)

      if Keyword.get(opts, :exclusive, false) do
        case put_new(config, key, body) do
          {:error, :no_conditional_writes} ->
            {:error,
             "s3 PUT #{shown(config, key)}: the bucket does not take If-None-Match, " <>
               "so it cannot write exclusively"}

          other ->
            other
        end
      else
        case call(config, :put, key, [body: body], deadline(config)) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          other -> failed(config, other, "PUT", key)
        end
      end
    end
  end

  defp check_body(body) when is_binary(body) or is_list(body), do: :ok
  defp check_body(_), do: {:error, "an object's body is iodata"}

  defp put_new(config, key, body) do
    token = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    exclusive(config, key, body, token, deadline(config), @attempts, false)
  end

  # `uncertain?`: an earlier attempt of this put may have been written.
  defp exclusive(config, key, body, token, deadline, attempts, uncertain?) do
    headers = [{"if-none-match", "*"}, {@token_header, token}]

    case attempt(config, :put, key, [body: body, headers: headers], deadline) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 412}} when not uncertain? ->
        {:error, :exists}

      {:ok, %{status: 412}} ->
        case settle(config, key, token, deadline) do
          :ours -> :ok
          :theirs -> {:error, :exists}
          :absent -> {:error, :exists}
          {:unknown, reason} -> {:error, unknown(config, key, reason)}
        end

      {:ok, %{status: 409}} ->
        again(config, key, body, token, deadline, attempts, uncertain?, "409 conflict")

      {:ok, %{status: 501}} ->
        {:error, :no_conditional_writes}

      {:ok, %{status: 400} = response} ->
        case error_code(response) do
          {"NotImplemented", _} -> {:error, :no_conditional_writes}
          _ -> failed(config, {:ok, response}, "PUT", key)
        end

      {:ok, %{status: status} = response} when status in @retry_statuses ->
        again(config, key, body, token, deadline, attempts, true, status_text(response))

      {:error, reason} ->
        again(config, key, body, token, deadline, attempts, true, reason_text(reason))

      other ->
        failed(config, other, "PUT", key)
    end
  end

  # Whether this put was written decides; when nothing is there it is tried
  # again, while attempts and time are left.
  defp again(config, key, body, token, deadline, attempts, uncertain?, why) do
    case settle(config, key, token, deadline) do
      :ours ->
        :ok

      :theirs ->
        {:error, :exists}

      :absent ->
        if attempts > 1 and pause(deadline, attempts),
          do: exclusive(config, key, body, token, deadline, attempts - 1, uncertain?),
          else:
            {:error,
             "s3 PUT #{shown(config, key)} exclusively: not written, and no attempt or " <>
               "time is left (#{why})"}

      {:unknown, reason} ->
        {:error, unknown(config, key, reason)}
    end
  end

  defp unknown(config, key, reason),
    do:
      "s3 PUT #{shown(config, key)} exclusively: the answer was lost, and whether it was " <>
        "written is not known: #{reason}"

  # Looks at the key: this put's object, somebody else's, or nothing.
  defp settle(config, key, token, deadline) do
    case call(config, :head, key, [], deadline) do
      {:ok, %{status: 200, headers: headers}} ->
        if token in Map.get(headers, @token_header, []), do: :ours, else: :theirs

      {:ok, %{status: 404}} ->
        :absent

      {:ok, response} ->
        {:unknown, status_text(response)}

      {:error, reason} ->
        {:unknown, reason_text(reason)}
    end
  end

  # ------------------------------------------------------------------ deleting

  @impl true
  def delete(config, key) do
    with :ok <- check_key(key) do
      case call(config, :delete, key, [], deadline(config)) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: 404} = response} -> missing(config, response, "DELETE", key, :ok)
        other -> failed(config, other, "DELETE", key)
      end
    end
  end

  # ------------------------------------------------------------------ listing

  @impl true
  def list(config, prefix, opts) do
    with :ok <- check_prefix(prefix) do
      delimiter = Keyword.get(opts, :delimiter, false)
      pages(config, prefix, delimiter, nil, deadline(config), [], MapSet.new(), MapSet.new())
    end
  end

  defp pages(config, prefix, delimiter, token, deadline, objects, prefixes, tokens) do
    query =
      [{"list-type", "2"}, {"prefix", full(config, prefix)}] ++
        if(delimiter, do: [{"delimiter", "/"}], else: []) ++
        if(token, do: [{"continuation-token", token}], else: [])

    with {:ok, page} <- page(config, prefix, query, deadline) do
      objects = Enum.reverse(page.objects, objects)
      prefixes = Enum.into(page.prefixes, prefixes)

      cond do
        not page.truncated ->
          {:ok,
           %{
             objects: objects |> Enum.uniq_by(& &1.key) |> Enum.sort_by(& &1.key),
             prefixes: Enum.sort(prefixes)
           }}

        page.token in [nil, ""] ->
          {:error, "s3 list #{shown(config, prefix)}: a page said more follow and gave no token"}

        MapSet.member?(tokens, page.token) ->
          {:error, "s3 list #{shown(config, prefix)}: the bucket gave a token it gave before"}

        true ->
          tokens = MapSet.put(tokens, page.token)
          pages(config, prefix, delimiter, page.token, deadline, objects, prefixes, tokens)
      end
    end
  end

  defp page(config, prefix, query, deadline) do
    case call(config, :list, nil, [query: query], deadline) do
      {:ok, %{status: 200, body: body}} ->
        case parse_listing(body) do
          {:ok, page} ->
            {:ok,
             %{
               page
               | objects: own_objects(config, page.objects),
                 prefixes: own_prefixes(config, page.prefixes)
             }}

          :error ->
            {:error, "s3 list #{shown(config, prefix)}: the answer is not a listing"}
        end

      {:ok, %{status: 404} = response} ->
        case error_code(response) do
          {"NoSuchBucket", _} -> {:error, no_bucket(config, "list", prefix)}
          _ -> failed(config, {:ok, response}, "list", prefix)
        end

      other ->
        failed(config, other, "list", prefix)
    end
  end

  # Keys as the store names them: the store's prefix taken off, and those it
  # could not address left out.
  defp own_objects(config, objects) do
    for %{key: key} = object <- objects,
        {:ok, own} <- [strip(config, key)],
        Store.check_key(own) == :ok,
        do: %{object | key: own}
  end

  defp own_prefixes(config, prefixes) do
    for prefix <- prefixes,
        {:ok, own} <- [strip(config, prefix)],
        String.ends_with?(own, "/"),
        Store.check_prefix(own) == :ok,
        do: own
  end

  defp strip(%{prefix: ""}, key), do: {:ok, key}

  defp strip(%{prefix: prefix}, key) do
    size = byte_size(prefix)

    case key do
      <<^prefix::binary-size(^size), "/", own::binary>> when own != "" -> {:ok, own}
      _ -> :error
    end
  end

  # ------------------------------------------------------------------ XML

  @doc false
  # A ListObjectsV2 answer: its objects, common prefixes, whether more
  # follow and the token for them. Element names stay charlists; no atom is
  # made of anything in the document.
  @spec parse_listing(binary()) :: {:ok, map()} | :error
  def parse_listing(xml) do
    initial = %{
      path: [],
      text: [],
      object: %{},
      objects: [],
      prefixes: [],
      truncated: false,
      token: nil,
      bad: false
    }

    case sax(xml, &listing_event/3, initial) do
      {:ok, %{bad: false, path: []} = state} ->
        {:ok,
         %{
           objects: Enum.reverse(state.objects),
           prefixes: Enum.reverse(state.prefixes),
           truncated: state.truncated,
           token: state.token
         }}

      _ ->
        :error
    end
  end

  defp listing_event({:startElement, _uri, name, _qname, _attrs}, _loc, state),
    do: %{state | path: [name | state.path], text: []}

  defp listing_event({:characters, chars}, _loc, state), do: %{state | text: [state.text, chars]}

  defp listing_event({:endElement, _uri, name, _qname}, _loc, state) do
    text = state.text |> List.flatten() |> List.to_string()
    state = %{state | path: tl(state.path), text: []}

    case {name, state.path} do
      {~c"Key", [~c"Contents" | _]} ->
        put_in(state.object[:key], text)

      {~c"Size", [~c"Contents" | _]} ->
        case Integer.parse(text) do
          {size, ""} when size >= 0 -> put_in(state.object[:size], size)
          _ -> %{state | bad: true}
        end

      {~c"ETag", [~c"Contents" | _]} ->
        put_in(state.object[:version], String.trim(text, "\""))

      {~c"Contents", _} ->
        case state.object do
          %{key: key, size: size} = object ->
            object = %{key: key, size: size, version: Map.get(object, :version, "")}
            %{state | objects: [object | state.objects], object: %{}}

          _ ->
            %{state | bad: true}
        end

      {~c"Prefix", [~c"CommonPrefixes" | _]} ->
        %{state | prefixes: [text | state.prefixes]}

      {~c"IsTruncated", [~c"ListBucketResult"]} ->
        %{state | truncated: text == "true"}

      {~c"NextContinuationToken", [~c"ListBucketResult"]} ->
        %{state | token: text}

      _ ->
        state
    end
  end

  defp listing_event(_event, _loc, state), do: state

  # An S3 error document's Code and Message, or empty strings.
  defp error_code(%{body: body}) when is_binary(body) and body != "" do
    event = fn
      {:startElement, _, name, _, _}, _, {path, _text, found} ->
        {[name | path], [], found}

      {:characters, chars}, _, {path, text, found} ->
        {path, [text, chars], found}

      {:endElement, _, name, _}, _, {[_ | path], text, found} ->
        if name in [~c"Code", ~c"Message"] and path == [~c"Error"],
          do: {path, [], Map.put(found, name, text |> List.flatten() |> List.to_string())},
          else: {path, [], found}

      _, _, state ->
        state
    end

    case sax(body, event, {[], [], %{}}) do
      {:ok, {_, _, found}} -> {Map.get(found, ~c"Code", ""), Map.get(found, ~c"Message", "")}
      _ -> {"", ""}
    end
  end

  defp error_code(_), do: {"", ""}

  defp sax(xml, event, state) do
    case :xmerl_sax_parser.stream(xml, [
           :disallow_entities,
           {:external_entities, :none},
           {:event_fun, event},
           {:event_state, state}
         ]) do
      {:ok, state, _rest} -> {:ok, state}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  # ------------------------------------------------------------------ replicas

  @impl true
  def replica(config, prefix) do
    case Store.check_key(prefix) do
      :ok ->
        {id, secret} = config.credentials.()

        opts =
          if(config.endpoint, do: [endpoint: config.endpoint], else: []) ++
            [region: config.region, access_key_id: id, secret_access_key: secret]

        {"s3://#{config.bucket}/#{full(config, prefix)}", opts}

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  # ------------------------------------------------------------------ probing

  @impl true
  def probe(config) do
    ops = %{
      put: &put_for_probe(config, &1, &2, &3),
      get: &get(config, &1),
      delete: &delete(config, &1)
    }

    case Store.probe_cas(ops) do
      {:error, :no_conditional_writes} -> {:ok, %{cas: false}}
      other -> other
    end
  end

  # As put/4, but a bucket without conditional writes is an answer the
  # probe turns into `cas: false`.
  defp put_for_probe(config, key, body, opts) do
    if Keyword.get(opts, :exclusive, false) do
      with :ok <- check_key(key), do: put_new(config, key, IO.iodata_to_binary(body))
    else
      put(config, key, body, opts)
    end
  end

  # ------------------------------------------------------------------ requests

  defp deadline(config), do: System.monotonic_time(:millisecond) + config.timeout

  # One request, retried while it may be and time is left.
  defp call(config, op, key, opts, deadline, attempts \\ @attempts) do
    result = attempt(config, op, key, opts, deadline)

    if attempts > 1 and retry?(result) and pause(deadline, attempts),
      do: call(config, op, key, opts, deadline, attempts - 1),
      else: result
  end

  defp retry?({:ok, %{status: status}}), do: status in @retry_statuses
  defp retry?({:error, _}), do: true

  # Waits before another attempt, when there is time for one.
  defp pause(deadline, attempts) do
    wait = @backoff * Integer.pow(2, @attempts - attempts)

    if deadline - System.monotonic_time(:millisecond) > wait do
      Process.sleep(wait)
      true
    else
      false
    end
  end

  # One request in a process of its own, killed when its time is up.
  defp attempt(config, op, key, opts, deadline) do
    limit =
      min(
        @connect_timeout + config.receive_timeout,
        deadline - System.monotonic_time(:millisecond)
      )

    if limit <= 0 do
      {:error, {:timeout, config.timeout}}
    else
      task = Task.async(fn -> send_request(config, op, key, opts) end)

      case Task.yield(task, limit) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _} -> {:error, :crashed}
        nil -> {:error, {:timeout, limit}}
      end
    end
  end

  defp send_request(config, op, key, opts) do
    {id, secret} = config.credentials.()

    request = [
      method: method(op),
      url: url(config, key, Keyword.get(opts, :query, [])),
      headers: Keyword.get(opts, :headers, []),
      body: Keyword.get(opts, :body, ""),
      aws_sigv4: [
        access_key_id: id,
        secret_access_key: secret,
        region: config.region,
        service: :s3
      ],
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      cache: false,
      receive_timeout: config.receive_timeout,
      connect_options: [timeout: @connect_timeout]
    ]

    try do
      case Req.request(request) do
        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          {:ok, %{status: status, headers: headers, body: body}}

        {:error, %{reason: :timeout}} ->
          {:error, {:timeout, config.receive_timeout}}

        {:error, exception} ->
          {:error, {:transport, exception_text(exception)}}
      end
    rescue
      exception -> {:error, {:transport, exception_text(exception)}}
    end
  end

  # Only the message of an exception whose message is about the
  # connection; anything else by its name, so that nothing from the request
  # (whose options hold the keys) can reach a reason.
  defp exception_text(%module{} = exception)
       when module in [Req.TransportError, Mint.TransportError, Mint.HTTPError, Finch.Error],
       do: Exception.message(exception)

  defp exception_text(%module{}), do: "the request failed (#{inspect(module)})"

  defp method(:get), do: :get
  defp method(:head), do: :head
  defp method(:put), do: :put
  defp method(:delete), do: :delete
  defp method(:list), do: :get

  defp url(config, key, query) do
    path =
      case {config.path_style, key} do
        {true, nil} -> "/" <> config.bucket
        {false, nil} -> "/"
        {true, key} -> "/" <> config.bucket <> "/" <> encode(full(config, key), true)
        {false, key} -> "/" <> encode(full(config, key), true)
      end

    case query do
      [] -> config.base <> path
      query -> config.base <> path <> "?" <> Enum.map_join(query, "&", &pair/1)
    end
  end

  defp pair({name, value}), do: encode(name, false) <> "=" <> encode(value, false)

  defp encode(s, keep_slash?),
    do: URI.encode(s, &(URI.char_unreserved?(&1) or (keep_slash? and &1 == ?/)))

  defp full(%{prefix: ""}, key), do: key
  defp full(%{prefix: prefix}, key), do: prefix <> "/" <> key

  # ------------------------------------------------------------------ reasons

  defp failed(config, {:ok, %{status: 404} = response}, method, key) do
    case error_code(response) do
      {"NoSuchBucket", _} -> {:error, no_bucket(config, method, key)}
      _ -> {:error, "s3 #{method} #{shown(config, key)}: #{status_text(response)}"}
    end
  end

  defp failed(config, {:ok, response}, method, key) do
    text = "s3 #{method} #{shown(config, key)}: #{status_text(response)}"

    case response.status do
      403 -> {:error, text <> " (check the store's credentials and the bucket's policy)"}
      _ -> {:error, text}
    end
  end

  defp failed(config, {:error, reason}, method, key),
    do: {:error, "s3 #{method} #{shown(config, key)}: #{reason_text(reason)}"}

  defp no_bucket(config, method, key),
    do: "s3 #{method} #{shown(config, key)}: the bucket #{config.bucket} does not exist"

  defp status_text(response) do
    case error_code(response) do
      {"", _} -> "answered #{response.status}"
      {code, ""} -> "answered #{response.status} #{code}"
      {code, message} -> "answered #{response.status} #{code}: #{message}"
    end
  end

  defp reason_text({:timeout, ms}), do: "no answer within #{ms} ms"
  defp reason_text({:transport, text}), do: text
  defp reason_text(:crashed), do: "the request crashed"

  defp shown(config, key), do: "#{config.base} #{config.bucket}/#{full(config, key)}"

  # ------------------------------------------------------------------ keys

  defp check_key(key), do: Store.check_key(key)
  defp check_prefix(prefix), do: Store.check_prefix(prefix)
end
