defmodule Aerotow.TowCase do
  @moduledoc """
  What the facade's tests share: whole instances started with
  `start_supervised!/2`, an S3 fake, a clock the test moves, and telemetry
  sent to the test process.
  """

  import ExUnit.Callbacks

  alias Aerotow.FakeS3

  # A lease long enough that a machine under load never loses one in a test
  # that is not about leases.
  @timing %{ttl: 300_000, margin: 5_000, grace: 5_000}

  @doc "A name no other test uses."
  @spec name(String.t()) :: atom()
  def name(label \\ "tow"),
    do: :"aerotow_#{label}_#{System.unique_integer([:positive])}"

  @doc """
  Starts an instance named `name` in `dir`, under the test's supervisor,
  and answers its name. Options are `Aerotow.start_link/1`'s; by default the
  timers that would make a test depend on time are off (`scan_interval:
  nil`, `idle: :infinity`, a long `sync_interval`, and a lease of five
  minutes).
  """
  @spec tow(Path.t(), keyword()) :: atom()
  def tow(dir, opts \\ []) do
    name = Keyword.get_lazy(opts, :name, fn -> name() end)

    opts =
      [
        name: name,
        dir: dir,
        scan_interval: nil,
        idle: :infinity,
        sync_interval: 3_600_000,
        timing: @timing
      ]
      |> Keyword.merge(opts)

    start_supervised!({Aerotow, opts}, id: name)
    name
  end

  @doc "An S3 fake with the bucket `graphs`, and the options an s3 store on it takes."
  @spec s3() :: {pid(), keyword()}
  def s3 do
    fake = start_supervised!({FakeS3, buckets: ["graphs"]}, id: make_ref())
    creds = FakeS3.credentials()

    {fake,
     [
       endpoint: FakeS3.endpoint(fake),
       access_key_id: creds.access_key_id,
       secret_access_key: creds.secret_access_key
     ]}
  end

  @doc "A clock the test moves: `{clock, set}`."
  @spec clock(integer()) :: {(-> integer()), (integer() -> :ok)}
  def clock(t \\ 1_763_400_000_000), do: Aerotow.FlightCase.clock(t)

  @doc "Sends the telemetry events named to the test process, as `Aerotow.FlightCase.listen/1`."
  @spec listen([[atom()]]) :: :ok
  def listen(events), do: Aerotow.FlightCase.listen(events)

  @doc "The rows of a `find/3` or `query/5`, or the error."
  @spec rows({:ok, Glider.Result.t()} | {:error, term()}) :: list() | {:error, term()}
  def rows({:ok, %{rows: rows}}), do: rows
  def rows(error), do: error
end
