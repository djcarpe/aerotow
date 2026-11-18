defmodule Aerotow.FakeS3 do
  @moduledoc """
  An S3 for tests: a server on `127.0.0.1`, on a port the OS picks, holding
  objects in memory. It is enough of S3 for both of aerotow's clients,
  `Aerotow.Store.S3` (over Req) and glider's own (inside the NIF):

    * `PUT`, `GET`, `HEAD` and `DELETE` of an object, path-style
      (`/<bucket>/<key>`). A `PUT` with `If-None-Match: *` answers 412 when
      the key exists, and of concurrent ones for the same key exactly one is
      written (`:ets.insert_new/2`). `x-amz-meta-*` headers are kept with the
      object and given back by `GET` and `HEAD`.
    * `GET /<bucket>?list-type=2` with `prefix`, `delimiter`, `max-keys`,
      `start-after` and `continuation-token`, answering `Contents`,
      `CommonPrefixes`, `IsTruncated` and `NextContinuationToken`, keys in
      byte order. A common prefix counts once towards a page and is never
      repeated on a later one.
    * An `ETag` that is the MD5 of the content, as S3 gives for a single put.
    * SigV4 is checked in full: a request with no `Authorization` header, an
      access key it does not know, a body whose hash is not the
      `x-amz-content-sha256` it came with, or a signature that is not the
      one the secret makes, is refused with 403 (400 for the body hash). So
      a client that signs a key's encoding differently from how it sends it
      fails here as it would against AWS.

  A missing bucket is 404 `NoSuchBucket`.

  ## Switches

  A test flips these while the fake runs:

    * `fail/2`: answer the next N requests with 500, writing nothing;
    * `stall/3`: hold the next N requests for a time, then answer 503,
      writing nothing;
    * `lose/2`: carry out the next N requests and then answer 500, as when
      the answer to a write that was made is lost on the way back;
    * `conflict/2`: answer the next N requests with 409
      `ConditionalRequestConflict`, writing nothing, as AWS answers a
      conditional put that raced another write of the same key;
    * `conditional/2`: `:honour` (the default), `:ignore` (a bucket without
      conditional writes, which writes whatever is there) or `:refuse`
      (answers 501 `NotImplemented` to `If-None-Match`);
    * `page_size/2`: the most keys a listing page holds, whatever the
      client asks for.

  A switch counts only requests that passed the signature check.
  `requests/1` is every request made so far, oldest first.

      fake = start_supervised!({Aerotow.FakeS3, buckets: ["graphs"]})
      Aerotow.FakeS3.endpoint(fake)
      #=> "http://127.0.0.1:41733"
  """

  use GenServer

  import Plug.Conn

  @default_id "AKIAFAKES3TESTKEY"
  @default_secret "fake/s3+secret+for+tests+only"
  @namespace "http://s3.amazonaws.com/doc/2006-03-01/"
  @max_body 64 * 1024 * 1024

  # ------------------------------------------------------------------ the server

  @doc """
  Starts a fake. Options: `buckets:` (the buckets there are, default
  `["bucket"]`), `access_key_id:` and `secret_access_key:` (the one pair it
  takes; defaults in `credentials/0`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "The access key id and secret a fake takes when none are given."
  @spec credentials() :: %{access_key_id: String.t(), secret_access_key: String.t()}
  def credentials, do: %{access_key_id: @default_id, secret_access_key: @default_secret}

  @doc "The fake's endpoint, `http://127.0.0.1:<port>`."
  @spec endpoint(GenServer.server()) :: String.t()
  def endpoint(fake), do: "http://127.0.0.1:#{GenServer.call(fake, :port)}"

  @doc "Answers the next `n` requests with 500, writing nothing."
  @spec fail(GenServer.server(), non_neg_integer()) :: :ok
  def fail(fake, n), do: set(fake, :fail, n)

  @doc "Holds the next `n` requests for `ms` milliseconds, then answers 503, writing nothing."
  @spec stall(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok
  def stall(fake, n, ms) do
    :ok = set(fake, :stall_ms, ms)
    set(fake, :stall, n)
  end

  @doc "Carries out the next `n` requests and then answers each with 500."
  @spec lose(GenServer.server(), non_neg_integer()) :: :ok
  def lose(fake, n), do: set(fake, :lose, n)

  @doc "Answers the next `n` requests with 409 `ConditionalRequestConflict`, writing nothing."
  @spec conflict(GenServer.server(), non_neg_integer()) :: :ok
  def conflict(fake, n), do: set(fake, :conflict, n)

  @doc "What `If-None-Match: *` does: `:honour`, `:ignore` or `:refuse`."
  @spec conditional(GenServer.server(), :honour | :ignore | :refuse) :: :ok
  def conditional(fake, mode) when mode in [:honour, :ignore, :refuse],
    do: set(fake, :conditional, mode)

  @doc "The most keys a listing page holds; `nil` is S3's own 1,000."
  @spec page_size(GenServer.server(), pos_integer() | nil) :: :ok
  def page_size(fake, n) when is_nil(n) or (is_integer(n) and n > 0),
    do: set(fake, :page_size, n)

  @doc "Every request made so far, oldest first: `%{method, bucket, key, query}`."
  @spec requests(GenServer.server()) :: [map()]
  def requests(fake) do
    %{requests: requests} = tables(fake)
    requests |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  end

  @doc "Forgets the requests made so far."
  @spec clear_requests(GenServer.server()) :: :ok
  def clear_requests(fake) do
    %{requests: requests} = tables(fake)
    true = :ets.delete_all_objects(requests)
    :ok
  end

  @doc "The keys in a bucket, in order."
  @spec keys(GenServer.server(), String.t()) :: [String.t()]
  def keys(fake, bucket) do
    %{objects: objects} = tables(fake)
    for {{^bucket, key}, _, _, _, _} <- :ets.tab2list(objects), do: key
  end

  defp set(fake, name, value) do
    %{control: control} = tables(fake)
    true = :ets.insert(control, {name, value})
    :ok
  end

  defp tables(fake), do: GenServer.call(fake, :tables)

  @impl GenServer
  def init(opts) do
    buckets = Keyword.get(opts, :buckets, ["bucket"])
    id = Keyword.get(opts, :access_key_id, @default_id)
    secret = Keyword.get(opts, :secret_access_key, @default_secret)

    tables = %{
      objects: :ets.new(:fake_s3_objects, [:ordered_set, :public]),
      control: :ets.new(:fake_s3_control, [:set, :public]),
      requests: :ets.new(:fake_s3_requests, [:ordered_set, :public])
    }

    true =
      :ets.insert(tables.control, [
        {:buckets, MapSet.new(buckets)},
        {:credentials, %{id => secret}},
        {:conditional, :honour},
        {:page_size, nil},
        {:fail, 0},
        {:stall, 0},
        {:lose, 0},
        {:conflict, 0},
        {:stall_ms, 0}
      ])

    {:ok, server} =
      Bandit.start_link(
        plug: {&__MODULE__.serve/2, tables},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{tables: tables, port: port, server: server}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:tables, _from, state), do: {:reply, state.tables, state}

  # ------------------------------------------------------------------ one request

  @doc false
  @spec serve(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def serve(conn, tables) do
    {:ok, body, conn} = read_all(conn, [])
    {bucket, key} = target(conn.request_path)
    query = query(conn.query_string)

    {status, headers, reply} =
      case authorize(conn, body, tables) do
        :ok ->
          :ets.insert(
            tables.requests,
            {System.unique_integer([:monotonic]),
             %{method: conn.method, bucket: bucket, key: key, query: Map.new(query)}}
          )

          faulted(tables, fn -> handle(conn.method, bucket, key, query, conn, body, tables) end)

        {:error, status, code, message} ->
          error(status, code, message)
      end

    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, if(conn.method == "HEAD", do: "", else: reply))
  end

  defp read_all(conn, acc) do
    case read_body(conn, length: @max_body) do
      {:ok, last, conn} -> {:ok, IO.iodata_to_binary([acc, last]), conn}
      {:more, part, conn} -> read_all(conn, [acc, part])
    end
  end

  # A switch that is on takes this request; otherwise it is carried out.
  defp faulted(tables, carry_out) do
    cond do
      take(tables, :fail) ->
        error(500, "InternalError", "We encountered an internal error. Please try again.")

      take(tables, :stall) ->
        [{:stall_ms, ms}] = :ets.lookup(tables.control, :stall_ms)

        receive do
        after
          ms -> error(503, "SlowDown", "Please reduce your request rate.")
        end

      take(tables, :conflict) ->
        error(409, "ConditionalRequestConflict", "A conflicting operation occurred.")

      take(tables, :lose) ->
        _ = carry_out.()
        error(500, "InternalError", "We encountered an internal error. Please try again.")

      true ->
        carry_out.()
    end
  end

  # Takes one from a counter when it is above zero, atomically.
  defp take(tables, name), do: :ets.update_counter(tables.control, name, {2, -1, -1, -1}) >= 0

  defp target(raw_path) do
    path = URI.decode(raw_path)

    case String.split(String.trim_leading(path, "/"), "/", parts: 2) do
      [""] -> {nil, nil}
      [bucket] -> {bucket, nil}
      [bucket, ""] -> {bucket, nil}
      [bucket, key] -> {bucket, key}
    end
  end

  defp query(""), do: []

  defp query(string) do
    for pair <- String.split(string, "&", trim: true) do
      case String.split(pair, "=", parts: 2) do
        [name, value] -> {URI.decode(name), URI.decode(value)}
        [name] -> {URI.decode(name), ""}
      end
    end
  end

  # ------------------------------------------------------------------ SigV4

  @authorization ~r/\AAWS4-HMAC-SHA256 Credential=([^\/,\s]+)\/(\d{8})\/([^\/,\s]+)\/s3\/aws4_request,\s*SignedHeaders=([a-z0-9;-]+),\s*Signature=([0-9a-f]{64})\z/

  defp authorize(conn, body, tables) do
    [{:credentials, credentials}] = :ets.lookup(tables.control, :credentials)

    with {:ok, header} <- header(conn, "authorization", "AccessDenied", "Access Denied"),
         {:ok, [id, date, region, signed, signature]} <- parse_authorization(header),
         {:ok, secret} <- secret(credentials, id),
         {:ok, datetime} <- header(conn, "x-amz-date", "AccessDenied", "no x-amz-date"),
         {:ok, hash} <- header(conn, "x-amz-content-sha256", "InvalidRequest", "no body hash"),
         :ok <- body_hash(hash, body),
         :ok <- signed_headers(signed) do
      canonical =
        Enum.join(
          [
            conn.method,
            canonical_path(conn.request_path),
            canonical_query(conn.query_string),
            canonical_headers(conn, signed),
            signed,
            hash
          ],
          "\n"
        )

      to_sign =
        Enum.join(
          [
            "AWS4-HMAC-SHA256",
            datetime,
            "#{date}/#{region}/s3/aws4_request",
            hex(:crypto.hash(:sha256, canonical))
          ],
          "\n"
        )

      key =
        ["AWS4" <> secret, date, region, "s3", "aws4_request"]
        |> Enum.reduce(fn data, key -> hmac(key, data) end)

      if Plug.Crypto.secure_compare(hex(hmac(key, to_sign)), signature),
        do: :ok,
        else:
          {:error, 403, "SignatureDoesNotMatch",
           "The request signature we calculated does not match the signature you provided."}
    end
  end

  defp header(conn, name, code, message) do
    case get_req_header(conn, name) do
      [value | _] -> {:ok, value}
      [] -> {:error, 403, code, message}
    end
  end

  defp parse_authorization(header) do
    case Regex.run(@authorization, header, capture: :all_but_first) do
      nil -> {:error, 403, "AccessDenied", "The authorization header is malformed."}
      parts -> {:ok, parts}
    end
  end

  defp secret(credentials, id) do
    case Map.fetch(credentials, id) do
      {:ok, secret} ->
        {:ok, secret}

      :error ->
        {:error, 403, "InvalidAccessKeyId",
         "The AWS Access Key Id you provided does not exist in our records."}
    end
  end

  defp body_hash("UNSIGNED-PAYLOAD", _body), do: :ok

  defp body_hash(hash, body) do
    if hex(:crypto.hash(:sha256, body)) == hash,
      do: :ok,
      else:
        {:error, 400, "XAmzContentSHA256Mismatch",
         "The provided 'x-amz-content-sha256' header does not match what was computed."}
  end

  defp signed_headers(signed) do
    names = String.split(signed, ";")

    if "host" in names and "x-amz-date" in names and "x-amz-content-sha256" in names,
      do: :ok,
      else: {:error, 403, "AccessDenied", "host, x-amz-date and the body hash must be signed."}
  end

  # The path as S3 signs it: decoded, then every byte but the unreserved
  # ones and `/` encoded.
  defp canonical_path(raw), do: raw |> URI.decode() |> encode(true)

  defp canonical_query(raw) do
    raw
    |> query()
    |> Enum.map(fn {name, value} -> {encode(name, false), encode(value, false)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> name <> "=" <> value end)
  end

  defp canonical_headers(conn, signed) do
    for name <- String.split(signed, ";"), into: "" do
      values =
        conn
        |> get_req_header(name)
        |> Enum.map_join(",", &(&1 |> String.trim() |> String.replace(~r/\s+/, " ")))

      name <> ":" <> values <> "\n"
    end
  end

  defp encode(s, keep_slash?),
    do: URI.encode(s, &(URI.char_unreserved?(&1) or (keep_slash? and &1 == ?/)))

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  # ------------------------------------------------------------------ operations

  defp handle(_method, nil, _key, _query, _conn, _body, _tables),
    do: error(400, "InvalidRequest", "This fake has no operations on the service itself.")

  defp handle(method, bucket, key, query, conn, body, tables) do
    [{:buckets, buckets}] = :ets.lookup(tables.control, :buckets)

    if MapSet.member?(buckets, bucket),
      do: operation(method, bucket, key, query, conn, body, tables),
      else: error(404, "NoSuchBucket", "The specified bucket does not exist.")
  end

  defp operation("GET", bucket, nil, query, _conn, _body, tables) do
    if List.keyfind(query, "list-type", 0) == {"list-type", "2"},
      do: list(bucket, Map.new(query), tables),
      else: error(400, "InvalidRequest", "This fake lists with list-type=2 only.")
  end

  defp operation("HEAD", _bucket, nil, _query, _conn, _body, _tables), do: {200, [], ""}

  defp operation("PUT", bucket, key, _query, conn, body, tables) when is_binary(key) do
    etag = :md5 |> :crypto.hash(body) |> hex()
    meta = for {"x-amz-meta-" <> _ = name, value} <- conn.req_headers, do: {name, value}
    object = {{bucket, key}, body, etag, meta, DateTime.utc_now()}
    [{:conditional, mode}] = :ets.lookup(tables.control, :conditional)

    case {get_req_header(conn, "if-none-match"), mode} do
      {[], _} ->
        true = :ets.insert(tables.objects, object)
        {200, [{"etag", ~s|"#{etag}"|}], ""}

      {_, :refuse} ->
        error(
          501,
          "NotImplemented",
          "A header you provided implies functionality that is not implemented."
        )

      {["*"], :honour} ->
        if :ets.insert_new(tables.objects, object),
          do: {200, [{"etag", ~s|"#{etag}"|}], ""},
          else:
            error(
              412,
              "PreconditionFailed",
              "At least one of the pre-conditions you specified did not hold"
            )

      {["*"], :ignore} ->
        true = :ets.insert(tables.objects, object)
        {200, [{"etag", ~s|"#{etag}"|}], ""}

      {_other, _} ->
        error(501, "NotImplemented", "If-None-Match takes only *.")
    end
  end

  defp operation(method, bucket, key, _query, _conn, _body, tables)
       when method in ["GET", "HEAD"] and is_binary(key) do
    case :ets.lookup(tables.objects, {bucket, key}) do
      [{_, body, etag, meta, _at}] ->
        {200, [{"etag", ~s|"#{etag}"|}, {"content-type", "binary/octet-stream"} | meta], body}

      [] ->
        error(404, "NoSuchKey", "The specified key does not exist.")
    end
  end

  defp operation("DELETE", bucket, key, _query, _conn, _body, tables) when is_binary(key) do
    true = :ets.delete(tables.objects, {bucket, key})
    {204, [], ""}
  end

  defp operation(_method, _bucket, _key, _query, _conn, _body, _tables),
    do:
      error(405, "MethodNotAllowed", "The specified method is not allowed against this resource.")

  # ------------------------------------------------------------------ listing

  defp list(bucket, query, tables) do
    prefix = Map.get(query, "prefix", "")
    delimiter = Map.get(query, "delimiter", "")
    [{:page_size, page_size}] = :ets.lookup(tables.control, :page_size)
    asked = query |> Map.get("max-keys", "1000") |> Integer.parse() |> max_keys()
    max = min(asked, page_size || 1000)

    with {:ok, after_entry} <- start(query) do
      entries =
        tables.objects
        |> :ets.select([{{{bucket, :"$1"}, :_, :"$2", :_, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
        |> Enum.filter(fn {key, _, _} -> String.starts_with?(key, prefix) end)
        |> collapse(prefix, delimiter)
        |> Enum.drop_while(fn entry -> after_entry != nil and name(entry) <= after_entry end)

      {page, rest} = Enum.split(entries, max)
      truncated = rest != []

      contents =
        for {:object, key, etag, at} <- page do
          size = :ets.lookup_element(tables.objects, {bucket, key}, 2) |> byte_size()

          [
            "<Contents><Key>",
            escape(key),
            "</Key><LastModified>",
            DateTime.to_iso8601(at),
            "</LastModified><ETag>&quot;",
            etag,
            "&quot;</ETag><Size>",
            Integer.to_string(size),
            "</Size><StorageClass>STANDARD</StorageClass></Contents>"
          ]
        end

      prefixes =
        for {:prefix, p} <- page,
            do: ["<CommonPrefixes><Prefix>", escape(p), "</Prefix></CommonPrefixes>"]

      next =
        if truncated,
          do: [
            "<NextContinuationToken>",
            page |> List.last() |> name() |> Base.url_encode64(),
            "</NextContinuationToken>"
          ],
          else: []

      xml = [
        ~s|<?xml version="1.0" encoding="UTF-8"?>\n<ListBucketResult xmlns="#{@namespace}">|,
        "<Name>",
        escape(bucket),
        "</Name><Prefix>",
        escape(prefix),
        "</Prefix>",
        if(delimiter == "", do: [], else: ["<Delimiter>", escape(delimiter), "</Delimiter>"]),
        "<KeyCount>",
        Integer.to_string(length(page)),
        "</KeyCount><MaxKeys>",
        Integer.to_string(max),
        "</MaxKeys><IsTruncated>",
        to_string(truncated),
        "</IsTruncated>",
        contents,
        prefixes,
        next,
        "</ListBucketResult>"
      ]

      {200, [{"content-type", "application/xml"}], IO.iodata_to_binary(xml)}
    end
  end

  defp max_keys({n, ""}) when n > 0, do: n
  defp max_keys(_), do: 1000

  # Where a page starts: after the entry a continuation token names, or
  # after `start-after`.
  defp start(%{"continuation-token" => token}) do
    case Base.url_decode64(token) do
      {:ok, entry} -> {:ok, entry}
      :error -> error(400, "InvalidArgument", "The continuation token provided is incorrect")
    end
  end

  defp start(%{"start-after" => key}), do: {:ok, key}
  defp start(_), do: {:ok, nil}

  # Keys in order become entries: an object, or, for keys with the delimiter
  # in the rest of their name, one common prefix for all of them.
  defp collapse(keys, _prefix, ""), do: Enum.map(keys, fn {k, e, at} -> {:object, k, e, at} end)

  defp collapse(keys, prefix, delimiter) do
    keys
    |> Enum.map(fn {key, etag, at} ->
      rest = binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix))

      case :binary.split(rest, delimiter) do
        [_whole] -> {:object, key, etag, at}
        [head, _tail] -> {:prefix, prefix <> head <> delimiter}
      end
    end)
    |> Enum.dedup()
  end

  defp name({:object, key, _, _}), do: key
  defp name({:prefix, prefix}), do: prefix

  # ------------------------------------------------------------------ answers

  defp error(status, code, message) do
    xml =
      ~s|<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>#{code}</Code><Message>#{escape(message)}</Message></Error>|

    {status, [{"content-type", "application/xml"}], xml}
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
