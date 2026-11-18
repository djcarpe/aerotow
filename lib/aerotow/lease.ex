defmodule Aerotow.Lease do
  @moduledoc """
  Flights: which instance holds a glider, decided by small records in its
  store.

  Glider has one writer per database, and nothing in a bucket can enforce
  that. A **flight** is one instance's turn with a glider, numbered per
  glider 1, 2, 3, …, and its record, `gliders/<ref>/_flights/<n>.json`, is the
  lease. This module is the record and the rules around it, R7 to R13 in the
  design: it reads and writes those records through `Aerotow.Store` and
  decides, on the clock it is given, who holds what. It opens no glider,
  ships nothing, and runs no process.

  ## The record

      {
        "format": 1,
        "ref": "engineering/code",
        "n": 7,
        "holder": "9c1e…",
        "node": "app@10.0.0.7",
        "url": "https://west.example.com/aerotow",
        "started_at": 1763400000000,
        "expires_at": 1763400030000,
        "from": {"flight": 6, "generation": "96348bfb…", "position": 1040112},
        "landed": false,
        "landed_at": null,
        "shipped": {"generation": "96348bfb…", "position": 1048665, "bases": 1}
      }

  Times are unix milliseconds on the holder's clock. `holder` is an
  instance's id; `node` and `url` are how another instance reaches it, and
  either may be null. `from` is where the flight started: an earlier
  flight's shipped state when it restored from one, `{"carried": true}` when
  it started from a copy this instance had kept, and null for a new glider
  or until the flight has restored. `shipped` is null until the flight has a
  whole base in the store.

  A record read from a store is input (R6). `decode/1` checks every field,
  bounds every size, ignores fields it does not know and makes no atom from
  anything in it; `read/3` also refuses a record whose `ref` and `n` are not
  the ones its key names.

  ## Who holds a glider

  The current flight is the one with the highest number (R8). It is
  `active?/3` while it has not landed and `now < expires_at + grace`, and a
  taker waits until it is not. Its holder acts on it only while it is
  `valid?/3`, `now < expires_at - margin`, and stops at `deadline/2` (R10,
  R11). Between the two lie `margin + grace`: when a taker's clock reaches
  `expires_at + grace`, the clock of a holder that is less than
  `margin + grace` behind it has passed `expires_at - margin`. So two
  instances whose clocks differ by less than that never both believe they
  hold the glider.

  ## Taking a glider up (R7, R9)

  `take/6` reads the clock, then the current flight. Active and somebody
  else's: `{:error, {:aloft, flight}}`, and nothing is written. Otherwise it
  creates flight `n + 1` with an exclusive put, of which, of any number of
  takers, exactly one wins (R7). A taker that loses reads again, and finds
  the winner aloft (R9). The winner then lists the flights once more, so that
  a flight created below a newer one (a retention pass made room while the
  taker waited) is never handed out. A new lease runs from the moment
  `take/6` read the clock, so a take that stalled hands back less time, never
  more.

  A store whose exclusive puts are not exclusive (`cas: false`) cannot hold
  a lease: `take/6` there is `{:error, :no_cas}`, unless the store is
  `single_writer: true`, the operator's promise that no second instance
  writes to it.

  An instance is the only process that holds flights under its own id
  (`Aerotow.Instance`), so a flight of its own with no process behind it is
  dead. Given `takeover_own: true`, `take/6` takes such a flight over at once
  instead of waiting for it to run out; the caller decides that it applies,
  and it applies only to the flight that was current when `take/6` looked.

  ## Holding it (R10)

  The holder renews with `renew/4` every `ttl / 3`, records where the flight
  started and what it shipped with `update/5`, and gives the glider back with
  `land/5`, after which it can be taken at once. Each of them first checks
  that the lease is still `valid?/3` on the clock, then that the store still
  says what its holder wrote: the record is this flight's, with the same
  holder, node, url and start, it has not landed and does not run out sooner
  than the lease says, and no higher flight exists. If any of that fails the
  answer is `{:error, :lost}`, and nothing is written. A renewal whose write
  completes after the lease's deadline is lost too, although its write went
  through: a taker may have read the record from before it.

  A store that fails is `{:error, reason}`, not `:lost`: a renewal that
  could not be made is tried again, and the flight is lost only when it
  reaches its deadline without one.

  Once lost, always lost. A lease lost to time stays behind its deadline on
  a clock that does not go back. One lost to the store stays lost because
  what was found does not come undone: only a flight's holder writes its
  record, a landed record stays landed, and retention deletes a flight only
  below a newer one with a whole base, long after the older flights'
  deadlines.

  ## Where to restore from (R12)

  `source/4` finds the newest flight below a given one that got a whole base
  into the store. It believes no record and no card about that: it asks
  `whole_base?`, a function of a flight's replica url and options that the
  caller builds on `Glider.Replication.generations/2`. A flight without a
  whole base is skipped through its `from`, so a flight that only read sends
  the search straight to where it started. A flight whose record is missing
  or unreadable, or that started from nothing or from a carried copy, gives
  way to the next lower flight. It visits each flight that exists at most
  once.

  ## Nothing is restored from a flight that is still active (R13)

  A launch restores from what `source/4` gives for the flight it holds, and
  `source/4` looks only below that number. The flight came from `take/6`,
  which creates flight `n + 1` only when flight `n` has landed, is past
  `expires_at + grace` on the taker's clock, or is this instance's own dead
  flight (`takeover_own: true`); each flight below `n` was superseded in the
  same way when the flight above it was created. A superseded holder never
  holds again: `renew/4`, `update/5` and `land/5` refuse once a higher flight
  exists, a renewal that completes after the deadline is refused, and by the
  time a taker's clock passes `expires_at + grace` the holder's has passed
  `expires_at - margin`, where it stops (R10, R11). So every flight
  `source/4` can choose has no holder that still acts on it: none of them is
  active.

  ## Retention

  `retire/5` deletes old flights: those below the newest flight with a whole
  base (found by asking `whole_base?`), with their records and everything
  under their directories, once they landed, or for one that never landed
  ran out, more than `older_than_ms` ago. It never deletes the newest flight
  with a whole base or anything above it, and leaves alone a flight whose
  record cannot be read. A flight's directory goes before its record, so a
  pass cut short leaves the record, and the next pass finishes the job. The
  design gives retention to the holder of the glider's current flight.

  ## Store operations

  Every function does a small, fixed number of store operations. A flight
  renews every few seconds for as long as it is aloft, so `renew/4` costs
  three.

  | function | operations |
  |---|---|
  | `flights/2` | a listing |
  | `read/3` | a get |
  | `current/2` | a listing and a get; only the listing when there are no flights |
  | `take/6` | a listing, a get, an exclusive put and a listing; a listing, a put and a listing for a new glider; two to four more for each race lost, at most two |
  | `renew/4`, `update/5`, `land/5` | a get, a listing and a put; a landing already made is a get |
  | `source/4` | a listing, then for each flight it visits a `whole_base?` call and at most one get |
  | `retire/5` | a listing, a `whole_base?` call for each flight from the top down to the newest with a whole base, a get for each flight below it, and for each flight retired a listing of its directory and a delete for each object in it and for its record |

  Every function that is given a ref parses it first (R1), and anything that
  is not what it takes is `{:error, reason}`, never a crash.
  """

  alias Aerotow.{Clock, Instance, Ref, Store}
  alias Aerotow.Store.Layout

  @format 1
  @max_record 65_536
  @max_flight Layout.max_flight()
  # The last millisecond of the year 9999: nothing later is a time.
  @max_time 253_402_300_799_999
  @attempts 3
  @id ~r/\A[0-9a-f]{32}\z/
  @generation ~r/\A[0-9a-fA-F]{1,64}\z/
  @digits ~r/\A[0-9]{10}\z/
  @control ~r/[\x00-\x1F\x7F]/
  @max_node 255
  @max_url 2_048

  @enforce_keys [:ref, :n, :holder, :started_at, :expires_at]
  defstruct ref: nil,
            n: nil,
            holder: nil,
            node: nil,
            url: nil,
            started_at: nil,
            expires_at: nil,
            from: nil,
            landed: false,
            landed_at: nil,
            shipped: nil

  @typedoc """
  Where a flight started: the state of an earlier flight it restored from
  (generation and position as far as it knows them), or a copy this
  instance carried into it.
  """
  @type from ::
          %{
            flight: pos_integer(),
            generation: String.t() | nil,
            position: non_neg_integer() | nil
          }
          | %{carried: true}

  @typedoc "What a flight has shipped: its generation, how far, and how many bases."
  @type shipped :: %{
          generation: String.t(),
          position: non_neg_integer(),
          bases: non_neg_integer()
        }

  @type t :: %__MODULE__{
          ref: Ref.t(),
          n: pos_integer(),
          holder: String.t(),
          node: String.t() | nil,
          url: String.t() | nil,
          started_at: non_neg_integer(),
          expires_at: non_neg_integer(),
          from: from() | nil,
          landed: boolean(),
          landed_at: non_neg_integer() | nil,
          shipped: shipped() | nil
        }

  @typedoc "Who is taking a glider: an instance's id, and how another instance reaches it."
  @type me :: %{id: String.t(), node: String.t() | nil, url: String.t() | nil}

  @typedoc """
  Whether the replica at a url holds a whole base. It is given the url and
  options `Aerotow.Store.replica/2` makes for a flight's directory.
  """
  @type whole_base :: (String.t(), keyword() -> {:ok, boolean()} | {:error, term()})

  # ------------------------------------------------------------------ JSON

  @doc """
  The record as JSON: one field a line, always in the same order, so the same
  lease is the same bytes.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = lease) do
    fields = [
      {"format", @format},
      {"ref", lease.ref},
      {"n", lease.n},
      {"holder", lease.holder},
      {"node", lease.node},
      {"url", lease.url},
      {"started_at", lease.started_at},
      {"expires_at", lease.expires_at},
      {"from", from_pairs(lease.from)},
      {"landed", lease.landed},
      {"landed_at", lease.landed_at},
      {"shipped", shipped_pairs(lease.shipped)}
    ]

    body = Enum.map_join(fields, ",\n  ", fn {k, v} -> [json(k), ": ", value(v)] end)
    IO.iodata_to_binary(["{\n  ", body, "\n}\n"])
  end

  defp from_pairs(nil), do: nil
  defp from_pairs(%{carried: true}), do: {:object, [{"carried", true}]}

  defp from_pairs(%{flight: flight} = from) do
    {:object,
     [
       {"flight", flight},
       {"generation", Map.get(from, :generation)},
       {"position", Map.get(from, :position)}
     ]}
  end

  defp shipped_pairs(nil), do: nil

  defp shipped_pairs(%{generation: generation, position: position, bases: bases}),
    do: {:object, [{"generation", generation}, {"position", position}, {"bases", bases}]}

  defp value({:object, pairs}),
    do: ["{", Enum.map_join(pairs, ", ", fn {k, v} -> [json(k), ": ", json(v)] end), "}"]

  defp value(v), do: json(v)

  defp json(v), do: v |> JSON.encode!() |> IO.iodata_to_binary()

  @doc """
  Reads a record from JSON that came from a store. Everything in it is
  checked, nothing in it becomes an atom, and fields this version does not
  know are ignored. Whether it is the record its key names is for `read/3`
  to say.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    if byte_size(json) > @max_record do
      {:error, "a flight record of #{byte_size(json)} bytes is too large"}
    else
      case JSON.decode(json) do
        {:ok, %{} = map} -> from_map(map)
        {:ok, _} -> {:error, "a flight record is a JSON object"}
        {:error, _} -> {:error, "a flight record is JSON, and this is not"}
      end
    end
  end

  def decode(other), do: {:error, "a flight record is JSON text, got: #{shown(other)}"}

  defp from_map(map) do
    with :ok <- format(map["format"]),
         {:ok, ref} <- record_ref(map["ref"]),
         {:ok, n} <- flight_number(map["n"], "a flight record's n"),
         {:ok, holder} <- id(map["holder"], "a flight record's holder"),
         {:ok, node} <- node_name(map["node"], "a flight record's node"),
         {:ok, url} <- url(map["url"], "a flight record's url"),
         {:ok, started_at} <- time(map["started_at"], "a flight record's started_at"),
         {:ok, expires_at} <- time(map["expires_at"], "a flight record's expires_at"),
         {:ok, from} <- from_in(map["from"], "a flight record's from"),
         :ok <- below(from, n),
         {:ok, landed, landed_at} <- landing(map["landed"], map["landed_at"]),
         {:ok, shipped} <- shipped_in(map["shipped"], "a flight record's shipped") do
      {:ok,
       %__MODULE__{
         ref: ref,
         n: n,
         holder: holder,
         node: node,
         url: url,
         started_at: started_at,
         expires_at: expires_at,
         from: from,
         landed: landed,
         landed_at: landed_at,
         shipped: shipped
       }}
    end
  end

  defp format(@format), do: :ok

  defp format(other) when is_integer(other),
    do: {:error, "a flight record of format #{other}; this aerotow reads format #{@format}"}

  defp format(other), do: {:error, "a flight record has a format, got: #{shown(other)}"}

  defp record_ref(ref) do
    case Ref.parse(ref) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, "a flight record's ref: " <> reason}
    end
  end

  defp flight_number(n, _label) when is_integer(n) and n >= 1 and n <= @max_flight, do: {:ok, n}

  defp flight_number(other, label),
    do: {:error, "#{label} is a flight number from 1 to #{@max_flight}, got: #{shown(other)}"}

  defp id(id, label) when is_binary(id) do
    if Regex.match?(@id, id),
      do: {:ok, id},
      else: {:error, "#{label} is an instance's id, 32 hex digits, got: #{shown(id)}"}
  end

  defp id(other, label),
    do: {:error, "#{label} is an instance's id, 32 hex digits, got: #{shown(other)}"}

  # A node's name is only ever compared with the names of connected nodes,
  # never made an atom (R16): here it is text with an @ in it.
  defp node_name(nil, _label), do: {:ok, nil}

  defp node_name(name, label) when is_binary(name) do
    if byte_size(name) <= @max_node and String.valid?(name) and
         not Regex.match?(@control, name) and String.contains?(name, "@"),
       do: {:ok, name},
       else: {:error, "#{label} is a node's name, name@host, or null, got: #{shown(name)}"}
  end

  defp node_name(other, label),
    do: {:error, "#{label} is a node's name, name@host, or null, got: #{shown(other)}"}

  # The url is written into the store for every instance to read, so one
  # with a user or a password in it is refused, and is never repeated in a
  # reason.
  defp url(nil, _label), do: {:ok, nil}

  defp url(url, label) when is_binary(url) and byte_size(url) <= @max_url do
    with true <- String.valid?(url) and not Regex.match?(@control, url),
         %URI{scheme: scheme, host: host, userinfo: nil}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.parse(url) do
      {:ok, url}
    else
      _ -> {:error, not_url(label)}
    end
  end

  defp url(_other, label), do: {:error, not_url(label)}

  defp not_url(label),
    do:
      "#{label} is an http or https url of at most #{@max_url} bytes, with no user or " <>
        "password in it, or null"

  defp time(t, _label) when is_integer(t) and t >= 0 and t <= @max_time, do: {:ok, t}

  defp time(other, label),
    do: {:error, "#{label} is a time in unix milliseconds, got: #{shown(other)}"}

  defp from_in(nil, _label), do: {:ok, nil}

  defp from_in(%{"carried" => true} = from, _label) when not is_map_key(from, "flight"),
    do: {:ok, %{carried: true}}

  defp from_in(%{"flight" => flight} = from, label) when not is_map_key(from, "carried") do
    with {:ok, flight} <- flight_number(flight, label <> ".flight"),
         {:ok, generation} <-
           nullable(from["generation"], &generation(&1, label <> ".generation")),
         {:ok, position} <- nullable(from["position"], &natural(&1, label <> ".position")) do
      {:ok, %{flight: flight, generation: generation, position: position}}
    end
  end

  defp from_in(other, label),
    do:
      {:error,
       "#{label} is null, {flight, generation, position} or {carried: true}, got: #{shown(other)}"}

  # What a flight started from is always an earlier flight.
  defp below(%{flight: flight}, n) when flight >= n,
    do: {:error, "a flight record's from names flight #{flight}, which is not below flight #{n}"}

  defp below(_from, _n), do: :ok

  defp landing(false, nil), do: {:ok, false, nil}

  defp landing(true, at) do
    with {:ok, at} <- time(at, "a flight record's landed_at"), do: {:ok, true, at}
  end

  defp landing(_landed, _at),
    do:
      {:error,
       "a flight record's landed is true, with landed_at the time it landed, or false, " <>
         "with landed_at null"}

  defp shipped_in(nil, _label), do: {:ok, nil}

  defp shipped_in(%{"generation" => generation, "position" => position, "bases" => bases}, label) do
    with {:ok, generation} <- generation(generation, label <> ".generation"),
         {:ok, position} <- natural(position, label <> ".position"),
         {:ok, bases} <- natural(bases, label <> ".bases") do
      {:ok, %{generation: generation, position: position, bases: bases}}
    end
  end

  defp shipped_in(other, label),
    do: {:error, "#{label} is null or {generation, position, bases}, got: #{shown(other)}"}

  defp generation(generation, label) when is_binary(generation) do
    if Regex.match?(@generation, generation),
      do: {:ok, generation},
      else: {:error, "#{label} is a generation, hex digits, got: #{shown(generation)}"}
  end

  defp generation(other, label),
    do: {:error, "#{label} is a generation, hex digits, got: #{shown(other)}"}

  defp natural(n, _label) when is_integer(n) and n >= 0, do: {:ok, n}
  defp natural(other, label), do: {:error, "#{label} is a whole number, got: #{shown(other)}"}

  defp nullable(nil, _check), do: {:ok, nil}
  defp nullable(value, check), do: check.(value)

  # A lease given to a function is checked as a record read from a store is,
  # so that what is written is always a record that reads back.
  defp check_lease(%__MODULE__{} = lease) do
    case from_map(to_map(lease)) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, "not a lease: " <> reason}
    end
  end

  defp check_lease(_other), do: {:error, "not a lease: expected an %Aerotow.Lease{}"}

  defp to_map(lease) do
    %{
      "format" => @format,
      "ref" => lease.ref,
      "n" => lease.n,
      "holder" => lease.holder,
      "node" => lease.node,
      "url" => lease.url,
      "started_at" => lease.started_at,
      "expires_at" => lease.expires_at,
      "from" => from_json(lease.from),
      "landed" => lease.landed,
      "landed_at" => lease.landed_at,
      "shipped" => shipped_json(lease.shipped)
    }
  end

  defp from_json(%{carried: true} = from) when map_size(from) == 1, do: %{"carried" => true}

  defp from_json(%{flight: flight} = from) do
    %{
      "flight" => flight,
      "generation" => Map.get(from, :generation),
      "position" => Map.get(from, :position)
    }
  end

  defp from_json(other), do: other

  defp shipped_json(%{generation: generation, position: position, bases: bases}),
    do: %{"generation" => generation, "position" => position, "bases" => bases}

  defp shipped_json(other), do: other

  # from: and shipped: as a caller gives them, with atom keys.
  defp external_from(nil), do: {:ok, nil}

  defp external_from(%{carried: true} = from) when map_size(from) == 1,
    do: {:ok, %{carried: true}}

  defp external_from(%{flight: flight} = from) do
    if Enum.all?(Map.keys(from), &(&1 in [:flight, :generation, :position])) do
      json = %{
        "flight" => flight,
        "generation" => Map.get(from, :generation),
        "position" => Map.get(from, :position)
      }

      from_in(json, "from")
    else
      {:error, not_from()}
    end
  end

  defp external_from(_other), do: {:error, not_from()}

  defp not_from,
    do: "from is nil, %{flight: n, generation: g, position: p} or %{carried: true}"

  defp external_shipped(nil), do: {:ok, nil}

  defp external_shipped(%{generation: generation, position: position, bases: bases} = shipped)
       when map_size(shipped) == 3 do
    json = %{"generation" => generation, "position" => position, "bases" => bases}
    shipped_in(json, "shipped")
  end

  defp external_shipped(_other),
    do: {:error, "shipped is nil or %{generation: g, position: p, bases: b}"}

  # ------------------------------------------------------------------ reading

  @doc """
  The numbers of the flights of `ref` that have a record, lowest first, from
  one listing of their keys. Nothing is read: what is under the flights'
  prefix and is not a record's key, such as the flights' directories and
  stray files, is not a flight.
  """
  @spec flights(Store.t(), Ref.t()) :: {:ok, [pos_integer()]} | {:error, term()}
  def flights(store, ref) do
    with :ok <- objects(store),
         {:ok, ref} <- Ref.parse(ref),
         {:ok, listing} <- listing(store, ref),
         do: {:ok, listing.records}
  end

  @doc """
  The record of flight `n` of `ref`, or `{:error, :not_found}`.

  The record is input: what is not a record, and a record whose `ref` or `n`
  is not the one its key names, is `{:error, reason}`.
  """
  @spec read(Store.t(), Ref.t(), pos_integer()) :: {:ok, t()} | {:error, :not_found | term()}
  def read(store, ref, n) do
    with :ok <- objects(store),
         {:ok, ref} <- Ref.parse(ref),
         {:ok, n} <- flight_number(n, "a flight's number") do
      case fetch(store, ref, n) do
        {:ok, lease} -> {:ok, lease}
        :missing -> {:error, :not_found}
        {:unreadable, reason} -> {:error, reason}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  The current flight of `ref`, the one with the highest number (R8), or
  `nil` when it has none.

  It never says a glider is free when it cannot tell. A highest record that
  cannot be read, or that went between the listing and the get, is
  `{:error, reason}`; so is a flight's directory numbered above every
  record, which means that a record some flight wrote under has gone.
  """
  @spec current(Store.t(), Ref.t()) :: {:ok, t() | nil} | {:error, term()}
  def current(store, ref) do
    with :ok <- objects(store), {:ok, ref} <- Ref.parse(ref), do: top(store, ref)
  end

  defp top(store, ref) do
    with {:ok, listing} <- listing(store, ref) do
      case {List.last(listing.records), highest(listing)} do
        {nil, 0} ->
          {:ok, nil}

        {n, n} ->
          current_record(store, ref, n)

        {_, n} ->
          {:error,
           "flight #{n} of #{ref} has data in the store and no record, so who holds " <>
             "#{ref} cannot be told"}
      end
    end
  end

  defp current_record(store, ref, n) do
    case fetch(store, ref, n) do
      {:ok, lease} ->
        {:ok, lease}

      :missing ->
        {:error, "flight #{n} of #{ref} was listed, and then its record was gone"}

      {:unreadable, reason} ->
        {:error, "the current flight of #{ref} cannot be read: #{reason}"}

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------ the rules

  @doc """
  Whether a flight is active at `now` (R8): it has not landed and `now` is
  before `expires_at + grace`. A taker waits until it is not.

      iex> lease = %Aerotow.Lease{ref: "a", n: 1, holder: String.duplicate("a", 32), started_at: 0, expires_at: 30_000}
      iex> timing = %{ttl: 30_000, margin: 5_000, grace: 5_000}
      iex> {Aerotow.Lease.active?(lease, 34_999, timing), Aerotow.Lease.active?(lease, 35_000, timing)}
      {true, false}
  """
  @spec active?(t(), integer(), Instance.timing()) :: boolean()
  def active?(%__MODULE__{landed: landed, expires_at: expires_at}, now, %{grace: grace})
      when is_integer(now),
      do: not landed and now < expires_at + grace

  @doc """
  Whether the holder of a lease may still act on it at `now` (R10, R11): it
  has not landed and `now` is before `deadline/2`.

      iex> lease = %Aerotow.Lease{ref: "a", n: 1, holder: String.duplicate("a", 32), started_at: 0, expires_at: 30_000}
      iex> timing = %{ttl: 30_000, margin: 5_000, grace: 5_000}
      iex> {Aerotow.Lease.valid?(lease, 24_999, timing), Aerotow.Lease.valid?(lease, 25_000, timing)}
      {true, false}
  """
  @spec valid?(t(), integer(), Instance.timing()) :: boolean()
  def valid?(%__MODULE__{landed: landed, expires_at: expires_at}, now, %{margin: margin})
      when is_integer(now),
      do: not landed and now < expires_at - margin

  @doc """
  When the holder of a lease stops: `expires_at - margin`, on its own clock.
  A flight that reaches it without a renewal that succeeded is lost (R10).

      iex> lease = %Aerotow.Lease{ref: "a", n: 1, holder: String.duplicate("a", 32), started_at: 0, expires_at: 30_000}
      iex> Aerotow.Lease.deadline(lease, %{ttl: 30_000, margin: 5_000, grace: 5_000})
      25000
  """
  @spec deadline(t(), Instance.timing()) :: integer()
  def deadline(%__MODULE__{expires_at: expires_at}, %{margin: margin}), do: expires_at - margin

  # ------------------------------------------------------------------ taking

  @doc """
  Takes `ref` up: creates its next flight, held by `me` (R7, R9).

  The current flight, read after the clock, decides. When it is active and
  not ours to take over, the answer is `{:error, {:aloft, flight}}` and
  nothing is written. Otherwise flight `n + 1` is created with an exclusive
  put; a taker that loses the race reads again. The lease runs from the
  moment the clock was read, for `ttl`.

  Options:

    * `create: true` - the glider is new: succeed only by creating flight 1.
      A glider that has any flight is `{:error, :exists}`
    * `from:` - what to record as `from`: `%{flight: n, generation: g,
      position: p}`, below the flight being created
    * `carried: true` - the flight starts from a copy this instance kept,
      not from the store; `from` is recorded as `%{carried: true}`
    * `takeover_own: true` - an active flight whose holder is `me.id` is
      taken over at once: the caller knows no process of its own holds it

  Without `create: true`, a glider with no flight is `{:error, :not_found}`.
  A store that cannot make an exclusive put is `{:error, :no_cas}` unless it
  is `single_writer`.
  """
  @spec take(Store.t(), Ref.t(), me(), Clock.t(), Instance.timing(), keyword()) ::
          {:ok, t()}
          | {:error, {:aloft, t()}}
          | {:error, :not_found | :exists | :no_cas | term()}
  def take(store, ref, me, clock, timing, opts \\ []) do
    with :ok <- objects(store),
         {:ok, ref} <- Ref.parse(ref),
         {:ok, me} <- check_me(me),
         :ok <- check_clock(clock),
         {:ok, timing} <- Instance.check_timing(timing),
         {:ok, opts} <- take_options(opts),
         :ok <- exclusive(store),
         {:ok, now} <- now(clock) do
      attempt(store, ref, me, now, timing, opts, @attempts)
    end
  end

  defp attempt(_store, ref, _me, _now, _timing, _opts, 0),
    do:
      {:error,
       "the flights of #{ref} changed hands #{@attempts} times while this instance " <>
         "was taking one"}

  defp attempt(store, ref, me, now, timing, opts, tries) do
    with {:ok, n} <- next_flight(store, ref, me, now, timing, opts),
         {:ok, lease} <- new_lease(ref, n, me, now, timing, opts.from) do
      case create(store, lease) do
        :ok -> confirm(store, lease, me, now, timing, opts, tries)
        :exists -> retry(store, ref, me, now, timing, opts, tries)
        {:error, _} = error -> error
      end
    end
  end

  # Somebody else just took off (R9). A flight of our own that appeared
  # meanwhile is not the dead one the caller meant: no takeover on a retry.
  defp retry(_store, _ref, _me, _now, _timing, %{create: true}, _tries), do: {:error, :exists}

  defp retry(store, ref, me, now, timing, opts, tries),
    do: attempt(store, ref, me, now, timing, %{opts | takeover_own: false}, tries - 1)

  # The flight just created must be the highest. One that came out below a
  # newer flight is never handed out: look again.
  defp confirm(store, lease, me, now, timing, opts, tries) do
    with {:ok, listing} <- listing(store, lease.ref) do
      if highest(listing) == lease.n,
        do: {:ok, lease},
        else: retry(store, lease.ref, me, now, timing, opts, tries)
    end
  end

  defp next_flight(store, ref, _me, _now, _timing, %{create: true}) do
    with {:ok, listing} <- listing(store, ref) do
      if highest(listing) == 0, do: {:ok, 1}, else: {:error, :exists}
    end
  end

  defp next_flight(store, ref, me, now, timing, opts) do
    case top(store, ref) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, current} -> after_flight(current, me, now, timing, opts)
      {:error, _} = error -> error
    end
  end

  defp after_flight(current, me, now, timing, opts) do
    cond do
      active?(current, now, timing) and not (opts.takeover_own and current.holder == me.id) ->
        {:error, {:aloft, current}}

      current.n >= @max_flight ->
        {:error,
         "#{current.ref} has had #{current.n} flights, as many as a record's key can number"}

      true ->
        {:ok, current.n + 1}
    end
  end

  defp new_lease(ref, n, me, now, timing, from) do
    check_lease(%__MODULE__{
      ref: ref,
      n: n,
      holder: me.id,
      node: me.node,
      url: me.url,
      started_at: now,
      expires_at: now + timing.ttl,
      from: from
    })
  end

  # Exclusive wherever the store can make it so; a single writer's store
  # that cannot gets a plain put, on the operator's promise.
  defp create(store, lease) do
    key = Layout.flight_record(lease.ref, lease.n)

    case Store.put(store, key, encode(lease), exclusive: store.cas == true) do
      :ok -> :ok
      {:error, :exists} -> :exists
      {:error, reason} -> {:error, "creating #{key}: #{text(reason)}"}
    end
  end

  defp exclusive(%Store{cas: true}), do: :ok
  defp exclusive(%Store{single_writer: true}), do: :ok
  defp exclusive(%Store{}), do: {:error, :no_cas}

  defp take_options(opts) do
    if Keyword.keyword?(opts) do
      initial = {:ok, %{create: false, carried: false, takeover_own: false, from: nil}}

      opts
      |> Enum.reduce_while(initial, &take_option/2)
      |> carried()
    else
      {:error, "take/6's options are a keyword list"}
    end
  end

  defp take_option({key, flag}, {:ok, acc})
       when key in [:create, :carried, :takeover_own] and is_boolean(flag),
       do: {:cont, {:ok, Map.put(acc, key, flag)}}

  defp take_option({key, other}, _acc) when key in [:create, :carried, :takeover_own],
    do: {:halt, {:error, "#{key} is true or false, got: #{shown(other)}"}}

  defp take_option({:from, from}, {:ok, acc}) do
    case external_from(from) do
      {:ok, from} -> {:cont, {:ok, %{acc | from: from}}}
      error -> {:halt, error}
    end
  end

  defp take_option({key, _value}, _acc),
    do:
      {:halt,
       {:error, "#{inspect(key)} is not an option of take/6: create, from, carried, takeover_own"}}

  defp carried({:ok, %{carried: true, from: nil} = opts}),
    do: {:ok, %{opts | from: %{carried: true}}}

  defp carried({:ok, %{carried: true, from: %{carried: true}}} = ok), do: ok

  defp carried({:ok, %{carried: true}}),
    do:
      {:error,
       "a flight starts from a carried copy or from the store: not both carried: and from:"}

  defp carried(result), do: result

  defp check_me(%{id: id} = me) do
    with {:ok, id} <- id(id, "me.id"),
         {:ok, node} <- node_name(Map.get(me, :node), "me.node"),
         {:ok, url} <- url(Map.get(me, :url), "me.url") do
      {:ok, %{id: id, node: node, url: url}}
    end
  end

  defp check_me(_other),
    do: {:error, "me is %{id: an instance's id, node: a node's name or nil, url: a url or nil}"}

  # ------------------------------------------------------------------ holding

  @doc """
  Renews a lease: `expires_at` becomes `now + ttl`, in the store and in the
  lease returned (R10).

  It is `{:error, :lost}`, and writes nothing, when the lease is no longer
  `valid?/3` at the time of the call; when the record in the store is no
  longer this flight's as its holder wrote it (another holder, landed,
  missing, unreadable); or when a higher flight exists. It is `:lost` as
  well when the write completes after the lease's deadline. A store that
  fails is `{:error, reason}`: try again before the deadline.
  """
  @spec renew(Store.t(), t(), Clock.t(), Instance.timing()) ::
          {:ok, t()} | {:error, :lost | term()}
  def renew(store, lease, clock, timing) do
    with :ok <- objects(store),
         {:ok, lease} <- check_lease(lease),
         :ok <- check_clock(clock),
         {:ok, timing} <- Instance.check_timing(timing),
         {:ok, now} <- now(clock),
         :ok <- still_valid(lease, now, timing),
         {:ok, renewed} <- check_lease(%{lease | expires_at: now + timing.ttl}),
         :ok <- held(store, lease),
         :ok <- write(store, renewed),
         {:ok, later} <- now(clock),
         :ok <- still_valid(lease, later, timing) do
      {:ok, renewed}
    end
  end

  @doc """
  Records where a flight started (`from:`) or what it has shipped
  (`shipped:`), in the store and in the lease returned.

  `from:` is `%{flight: n, generation: g, position: p}` of a flight below
  this one, or `%{carried: true}`; `shipped:` is `%{generation: g,
  position: p, bases: b}`; either may be `nil`. The lease is refused as
  `renew/4` refuses it, with `{:error, :lost}` and nothing written.
  """
  @spec update(Store.t(), t(), keyword(), Clock.t(), Instance.timing()) ::
          {:ok, t()} | {:error, :lost | term()}
  def update(store, lease, changes, clock, timing) do
    with :ok <- objects(store),
         {:ok, lease} <- check_lease(lease),
         {:ok, changes} <- check_changes(changes),
         :ok <- check_clock(clock),
         {:ok, timing} <- Instance.check_timing(timing),
         {:ok, updated} <- check_lease(struct(lease, changes)),
         {:ok, now} <- now(clock),
         :ok <- still_valid(lease, now, timing),
         :ok <- held(store, lease),
         :ok <- write(store, updated) do
      {:ok, updated}
    end
  end

  defp check_changes(changes) do
    if Keyword.keyword?(changes),
      do: Enum.reduce_while(changes, {:ok, %{}}, &change/2),
      else: {:error, "update/5's changes are a keyword list"}
  end

  defp change({:from, from}, {:ok, acc}) do
    case external_from(from) do
      {:ok, from} -> {:cont, {:ok, Map.put(acc, :from, from)}}
      error -> {:halt, error}
    end
  end

  defp change({:shipped, shipped}, {:ok, acc}) do
    case external_shipped(shipped) do
      {:ok, shipped} -> {:cont, {:ok, Map.put(acc, :shipped, shipped)}}
      error -> {:halt, error}
    end
  end

  defp change({key, _value}, _acc),
    do: {:halt, {:error, "#{inspect(key)} is not something update/5 changes: from, shipped"}}

  @doc """
  Lands a flight: its record says `landed`, when (`landed_at`, now) and what
  was shipped, and the glider can be taken at once.

  `shipped` is what the flight shipped, `%{generation: g, position: p,
  bases: b}`, or `nil` for one that shipped nothing. The lease is refused as
  `renew/4` refuses it, with `{:error, :lost}` and nothing written, so a
  landing that answers `{:ok, _}` was made while the lease still held. A
  landing that was made already, whose answer was lost, is answered with the
  record as it was landed.
  """
  @spec land(Store.t(), t(), shipped() | nil, Clock.t(), Instance.timing()) ::
          {:ok, t()} | {:error, :lost | term()}
  def land(store, lease, shipped, clock, timing) do
    with :ok <- objects(store),
         {:ok, lease} <- check_lease(lease),
         {:ok, shipped} <- external_shipped(shipped),
         :ok <- check_clock(clock),
         {:ok, timing} <- Instance.check_timing(timing),
         {:ok, now} <- now(clock),
         :ok <- still_valid(lease, now, timing),
         {:ok, landed} <- check_lease(%{lease | landed: true, landed_at: now, shipped: shipped}) do
      case standing(store, lease) do
        :held -> with :ok <- write(store, landed), do: {:ok, landed}
        {:landed, record} -> {:ok, record}
        :lost -> {:error, :lost}
        {:error, _} = error -> error
      end
    end
  end

  defp still_valid(lease, now, timing),
    do: if(valid?(lease, now, timing), do: :ok, else: {:error, :lost})

  defp held(store, lease) do
    case standing(store, lease) do
      :held -> :ok
      {:landed, _record} -> {:error, :lost}
      :lost -> {:error, :lost}
      {:error, _} = error -> error
    end
  end

  # What the store says of a lease's flight. :held when the record is still
  # this flight's as its holder wrote it and no higher flight exists;
  # {:landed, record} when this flight's record has landed; :lost otherwise.
  # A renewal or update whose answer was lost may have left a later expiry or
  # another from or shipped: that is still this holder's writing. A record
  # that runs out sooner than the lease is not.
  defp standing(store, %__MODULE__{ref: ref, n: n} = lease) do
    case fetch(store, ref, n) do
      {:ok, record} ->
        cond do
          not same_flight?(record, lease) -> :lost
          record.landed -> {:landed, record}
          record.expires_at < lease.expires_at -> :lost
          true -> highest_is(store, lease)
        end

      :missing ->
        :lost

      {:unreadable, _reason} ->
        :lost

      {:error, _} = error ->
        error
    end
  end

  defp same_flight?(a, b) do
    {a.ref, a.n, a.holder, a.node, a.url, a.started_at} ==
      {b.ref, b.n, b.holder, b.node, b.url, b.started_at}
  end

  defp highest_is(store, lease) do
    with {:ok, listing} <- listing(store, lease.ref) do
      if highest(listing) == lease.n, do: :held, else: :lost
    end
  end

  defp write(store, lease) do
    key = Layout.flight_record(lease.ref, lease.n)

    case Store.put(store, key, encode(lease)) do
      :ok -> :ok
      {:error, reason} -> {:error, "writing #{key}: #{text(reason)}"}
    end
  end

  # ------------------------------------------------------------------ the source

  @doc """
  Where a launch of flight `below` restores from (R12): the newest flight
  below it that got a whole base into the store, `%{flight: n}`, or `nil`
  when none did.

  `whole_base?` is asked about each flight's directory, with the url and
  options `Aerotow.Store.replica/2` makes for it, before anything is
  believed: a flight it says has a whole base is chosen whatever its record
  says, and a record that claims a base is not believed when it says no. A
  flight without one is skipped through its `from`; one whose record is
  missing or unreadable, or that started from nothing or from a carried
  copy, gives way to the next lower flight. Only flights below `below` are
  looked at (R13), each at most once.
  """
  @spec source(Store.t(), Ref.t(), pos_integer(), whole_base()) ::
          {:ok, %{flight: pos_integer()} | nil} | {:error, term()}
  def source(store, ref, below, whole_base?) do
    with :ok <- objects(store),
         {:ok, ref} <- Ref.parse(ref),
         :ok <- check_below(below),
         :ok <- check_whole_base(whole_base?),
         {:ok, listing} <- listing(store, ref) do
      candidates = listing |> numbers() |> Enum.filter(&(&1 < below)) |> Enum.sort(:desc)
      descend(store, ref, candidates, listing.records, whole_base?)
    end
  end

  defp descend(_store, _ref, [], _records, _whole_base?), do: {:ok, nil}

  defp descend(store, ref, [n | lower], records, whole_base?) do
    case whole_base(store, ref, n, whole_base?) do
      {:ok, true} ->
        {:ok, %{flight: n}}

      {:ok, false} ->
        with {:ok, lower} <- skip(store, ref, n, lower, records),
             do: descend(store, ref, lower, records, whole_base?)

      {:error, _} = error ->
        error
    end
  end

  # After a flight without a whole base: the flights at or below the one it
  # started from, or the next lower one when it says nothing usable.
  defp skip(store, ref, n, lower, records) do
    if n in records do
      case fetch(store, ref, n) do
        {:ok, %__MODULE__{from: %{flight: from}}} -> {:ok, Enum.drop_while(lower, &(&1 > from))}
        {:ok, _started_from_nothing_or_carried} -> {:ok, lower}
        :missing -> {:ok, lower}
        {:unreadable, _reason} -> {:ok, lower}
        {:error, _} = error -> error
      end
    else
      {:ok, lower}
    end
  end

  defp whole_base(store, ref, n, whole_base?) do
    case Store.replica(store, Layout.flight_data(ref, n)) do
      {url, opts} when is_binary(url) ->
        case ask(whole_base?, url, opts) do
          {:ok, answer} when is_boolean(answer) ->
            {:ok, answer}

          {:error, reason} ->
            {:error, "asking whether flight #{n} of #{ref} has a whole base: #{text(reason)}"}

          other ->
            {:error, "whole_base? answered #{shown(other)} for flight #{n} of #{ref}"}
        end

      {:error, reason} ->
        {:error, "the replica of flight #{n} of #{ref}: #{text(reason)}"}
    end
  end

  # The caller's function reads the store too; one that raises is an answer
  # about the store, not a crash of whoever asked.
  defp ask(whole_base?, url, opts) do
    whole_base?.(url, opts)
  catch
    kind, reason -> {:error, "it raised: " <> Exception.format_banner(kind, reason, [])}
  end

  defp check_below(below) when is_integer(below) and below >= 1, do: :ok
  defp check_below(other), do: {:error, "below is a flight number, got: #{shown(other)}"}

  defp check_whole_base(whole_base?) when is_function(whole_base?, 2), do: :ok

  defp check_whole_base(other),
    do: {:error, "whole_base? is a function of a replica's url and options, got: #{shown(other)}"}

  # ------------------------------------------------------------------ retention

  @doc """
  Deletes old flights of `ref`: below the newest flight with a whole base
  (`whole_base?` says which, as for `source/4`), each one that landed, or
  for one that never landed ran out, more than `older_than_ms` ago, its
  record and everything under its directory. Answers how many flights went.

  It never deletes the newest flight with a whole base or anything above it,
  and leaves alone a flight whose record cannot be read. With no whole base
  anywhere it deletes nothing. A flight's directory is deleted before its
  record, so a pass cut short leaves the record for the next one.
  """
  @spec retire(Store.t(), Ref.t(), Clock.t(), pos_integer(), whole_base()) ::
          {:ok, deleted :: non_neg_integer()} | {:error, term()}
  def retire(store, ref, clock, older_than_ms, whole_base?) do
    with :ok <- objects(store),
         {:ok, ref} <- Ref.parse(ref),
         :ok <- check_clock(clock),
         :ok <- check_age(older_than_ms),
         :ok <- check_whole_base(whole_base?),
         {:ok, now} <- now(clock),
         {:ok, listing} <- listing(store, ref),
         descending = listing |> numbers() |> Enum.sort(:desc),
         {:ok, newest} <- newest_base(store, ref, descending, whole_base?) do
      case newest do
        nil ->
          {:ok, 0}

        newest ->
          retire_below(
            store,
            ref,
            Enum.filter(listing.records, &(&1 < newest)),
            now - older_than_ms
          )
      end
    end
  end

  defp newest_base(_store, _ref, [], _whole_base?), do: {:ok, nil}

  defp newest_base(store, ref, [n | lower], whole_base?) do
    case whole_base(store, ref, n, whole_base?) do
      {:ok, true} -> {:ok, n}
      {:ok, false} -> newest_base(store, ref, lower, whole_base?)
      {:error, _} = error -> error
    end
  end

  defp retire_below(store, ref, records, before) do
    Enum.reduce_while(records, {:ok, 0}, fn n, {:ok, deleted} ->
      case fetch(store, ref, n) do
        {:ok, lease} ->
          if ended_at(lease) < before do
            case delete_flight(store, ref, n) do
              :ok -> {:cont, {:ok, deleted + 1}}
              error -> {:halt, error}
            end
          else
            {:cont, {:ok, deleted}}
          end

        :missing ->
          {:cont, {:ok, deleted}}

        {:unreadable, _reason} ->
          {:cont, {:ok, deleted}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # When a flight was over: when it landed, or for one that never landed,
  # when it ran out.
  defp ended_at(%__MODULE__{landed: true, landed_at: landed_at}), do: landed_at
  defp ended_at(%__MODULE__{expires_at: expires_at}), do: expires_at

  defp delete_flight(store, ref, n) do
    prefix = Layout.flight_data(ref, n) <> "/"

    case Store.list(store, prefix) do
      {:ok, %{objects: objects}} ->
        with :ok <- delete_each(store, Enum.map(objects, & &1.key)),
             do: delete_each(store, [Layout.flight_record(ref, n)])

      {:error, reason} ->
        {:error, "listing #{prefix}: #{text(reason)}"}
    end
  end

  defp delete_each(store, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Store.delete(store, key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "deleting #{key}: #{text(reason)}"}}
      end
    end)
  end

  defp check_age(ms) when is_integer(ms) and ms > 0, do: :ok

  defp check_age(other),
    do: {:error, "older_than_ms is a positive number of milliseconds, got: #{shown(other)}"}

  # ------------------------------------------------------------------ the store

  defp objects(%Store{} = store),
    do: if(Store.objects?(store), do: :ok, else: {:error, :not_objects})

  defp objects(_other), do: {:error, "not an Aerotow.Store"}

  # One listing of a glider's flights, with a delimiter: the numbers that
  # have a record, and the numbers that have a directory with something in
  # it, each lowest first.
  defp listing(store, ref) do
    prefix = Layout.flights_prefix(ref)

    case Store.list(store, prefix, delimiter: true) do
      {:ok, %{objects: objects, prefixes: prefixes}} ->
        records = for %{key: key} <- objects, {:ok, n} <- [record_number(ref, key)], do: n
        dirs = for dir <- prefixes, {:ok, n} <- [dir_number(prefix, dir)], do: n
        {:ok, %{records: Enum.sort(records), dirs: Enum.sort(dirs)}}

      {:error, reason} ->
        {:error, "listing #{prefix}: #{text(reason)}"}
    end
  end

  # Only a key spelt as Layout spells a record is one: flight_of_record/2
  # alone would also read "+000000007.json" as flight 7.
  defp record_number(ref, key) do
    case Layout.flight_of_record(ref, key) do
      {:ok, n} -> if key == Layout.flight_record(ref, n), do: {:ok, n}, else: :error
      :error -> :error
    end
  end

  defp dir_number(prefix, dir) do
    size = byte_size(prefix)

    with <<^prefix::binary-size(^size), digits::binary-size(10), "/">> <- dir,
         true <- Regex.match?(@digits, digits),
         n when n > 0 <- String.to_integer(digits) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp numbers(listing), do: Enum.uniq(listing.records ++ listing.dirs)

  defp highest(listing), do: Enum.max(numbers(listing), fn -> 0 end)

  # A record as the store has it: {:ok, lease}, :missing, {:unreadable,
  # reason} for what is not this flight's record, or {:error, reason} when
  # the store failed.
  defp fetch(store, ref, n) do
    key = Layout.flight_record(ref, n)

    case Store.get(store, key) do
      {:ok, body} ->
        case decode(body) do
          {:ok, %__MODULE__{ref: ^ref, n: ^n} = lease} ->
            {:ok, lease}

          {:ok, lease} ->
            {:unreadable, "#{key} holds the record of flight #{lease.n} of #{lease.ref}"}

          {:error, reason} ->
            {:unreadable, "#{key}: #{reason}"}
        end

      {:error, :not_found} ->
        :missing

      {:error, reason} ->
        {:error, "reading #{key}: #{text(reason)}"}
    end
  end

  # ------------------------------------------------------------------ helpers

  defp check_clock(:system), do: :ok
  defp check_clock(clock) when is_function(clock, 0), do: :ok

  defp check_clock(other),
    do: {:error, "a clock is :system or a function of no arguments, got: #{shown(other)}"}

  defp now(clock) do
    case Clock.now(clock) do
      now when is_integer(now) -> {:ok, now}
      other -> {:error, "the clock answered #{shown(other)}, which is not unix milliseconds"}
    end
  end

  defp shown(term), do: inspect(term, limit: 5, printable_limit: 80)

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)
end
