defmodule Aerotow.Options do
  @moduledoc """
  The options an instance is started with, checked.

  `Aerotow.start_link/1` takes a keyword list: `name:` (an atom) and `dir:`
  (the working directory) are required; `stores:`, `default_store:`, `id:`,
  `clock:`, `timing:`, `url:` and the limits and intervals listed in
  `Aerotow.Instance` are optional. An option that is not one of these is an
  error, so a typo does not quietly change nothing.

  A store is `{name, url, opts}` (or `{name, url}`), as `Aerotow.Store.new/3`
  takes it. Its options may hold credentials, so they are kept inside a
  function (`fn -> opts end`): neither `inspect/1` of what this module
  returns nor a crash report of a process that holds it shows them (R4). No
  reason given here repeats a store's options.
  """

  alias Aerotow.Instance

  @typedoc "A store as it was given: its options behind a function."
  @type store_spec :: %{name: String.t(), url: String.t(), opts: (-> keyword())}

  @typedoc "What `check/1` gives back: the instance's fields, and its stores."
  @type t :: %{
          name: atom(),
          dir: Path.t(),
          id: String.t() | nil,
          stores: [store_spec()],
          fields: keyword()
        }

  @known ~w(name dir stores default_store id clock timing url sync_interval sync_timeout
            launch_timeout idle max_aloft budget scan_interval retention memory_threshold
            mode hot max_memory cache_size)a

  @positive ~w(sync_interval sync_timeout launch_timeout max_aloft retention max_memory)a
  @id ~r/\A[0-9a-f]{32}\z/

  @doc """
  Checks an instance's options. Answers the instance's name, directory, the
  id it was given (if any), its stores and the rest of its fields, or a
  reason a person reads.
  """
  @spec check(term()) :: {:ok, t()} | {:error, String.t()}
  def check(opts) do
    with :ok <- keyword(opts),
         :ok <- known(opts),
         {:ok, name} <- name(opts[:name]),
         {:ok, dir} <- dir(opts[:dir]),
         {:ok, id} <- id(opts[:id]),
         {:ok, stores} <- stores(Keyword.get(opts, :stores, [])),
         {:ok, fields} <- fields(opts, stores) do
      {:ok, %{name: name, dir: dir, id: id, stores: stores, fields: fields}}
    end
  end

  defp keyword(opts) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: :ok,
      else: {:error, "an aerotow's options are a keyword list"}
  end

  defp known(opts) do
    case Enum.reject(Keyword.keys(opts), &(&1 in @known)) do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown options: #{Enum.map_join(unknown, ", ", &inspect/1)} (an aerotow takes " <>
           "#{Enum.map_join(@known, ", ", &inspect/1)})"}
    end
  end

  defp name(name) when is_atom(name) and name not in [nil, true, false], do: {:ok, name}
  defp name(nil), do: {:error, "an aerotow needs name: an atom, which callers pass as tow"}
  defp name(other), do: {:error, "name is an atom, got: #{inspect(other)}"}

  defp dir(dir) when is_binary(dir) and dir != "", do: {:ok, Path.expand(dir)}
  defp dir(nil), do: {:error, "an aerotow needs dir: its working directory"}
  defp dir(other), do: {:error, "dir is a path, got: #{inspect(other)}"}

  defp id(nil), do: {:ok, nil}

  defp id(id) when is_binary(id) do
    if Regex.match?(@id, id),
      do: {:ok, id},
      else: {:error, "id is 32 lower-case hex digits, got: #{inspect(id)}"}
  end

  defp id(other), do: {:error, "id is 32 lower-case hex digits, got: #{inspect(other)}"}

  defp stores(list) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {spec, i}, {:ok, acc} ->
      case store(spec, i) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, specs} ->
        specs = Enum.reverse(specs)
        names = Enum.map(specs, & &1.name)

        case names -- Enum.uniq(names) do
          [] -> {:ok, specs}
          [twice | _] -> {:error, "two stores are named #{inspect(twice)}"}
        end

      error ->
        error
    end
  end

  defp stores(_other), do: {:error, "stores is a list of {name, url, opts}"}

  @doc """
  Checks one store as given: `{name, url, opts}` or `{name, url}`, with a
  name and url that are strings and options that are a keyword list. What
  the store's kind makes of them is for `Aerotow.Store.new/3`.
  """
  @spec store(term(), pos_integer()) :: {:ok, store_spec()} | {:error, String.t()}
  def store(spec, i \\ 1)
  def store({name, url}, i), do: store({name, url, []}, i)

  def store({name, url, opts}, i) do
    cond do
      not is_binary(name) ->
        {:error, "store #{i}: its name is a string, got: #{inspect(name)}"}

      not is_binary(url) ->
        {:error, "store #{inspect(name)}: its url is a string"}

      not (is_list(opts) and Keyword.keyword?(opts)) ->
        {:error, "store #{inspect(name)}: its options are a keyword list"}

      true ->
        {:ok, %{name: name, url: url, opts: fn -> opts end}}
    end
  end

  def store(_other, i), do: {:error, "store #{i} is not {name, url, opts}"}

  defp fields(opts, stores) do
    checks = [
      clock: &clock/1,
      timing: &timing/1,
      url: &url/1,
      idle: &idle/1,
      budget: &optional_positive(&1, :budget),
      scan_interval: &optional_positive(&1, :scan_interval),
      memory_threshold: &memory_threshold/1,
      cache_size: &optional_positive(&1, :cache_size),
      mode: &mode/1,
      hot: &hot/1,
      default_store: &default_store(&1, stores)
    ]

    positives = Enum.map(@positive, fn key -> {key, &positive(&1, key)} end)

    Enum.reduce_while(checks ++ positives, {:ok, []}, fn {key, check}, {:ok, acc} ->
      if Keyword.has_key?(opts, key) do
        case check.(Keyword.fetch!(opts, key)) do
          {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp clock(:system), do: {:ok, :system}
  defp clock(clock) when is_function(clock, 0), do: {:ok, clock}

  defp clock(other),
    do: {:error, "clock is :system or a function of no arguments, got: #{inspect(other)}"}

  defp timing(timing) when is_list(timing) or is_map(timing) do
    if is_map(timing) or Keyword.keyword?(timing) do
      %Instance{name: :x, id: "", dir: ""}.timing
      |> Map.merge(Map.new(timing))
      |> Instance.check_timing()
    else
      {:error, "timing is %{ttl: ms, margin: ms, grace: ms}"}
    end
  end

  defp timing(_other), do: {:error, "timing is %{ttl: ms, margin: ms, grace: ms}"}

  defp url(nil), do: {:ok, nil}

  defp url(url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) and String.valid?(url) and
         byte_size(url) <= 2_048,
       do: {:ok, url},
       else: {:error, "url is where this instance's plug is served, http(s)://…"}
  end

  defp url(_other), do: {:error, "url is where this instance's plug is served, http(s)://…"}

  defp idle(:infinity), do: {:ok, :infinity}
  defp idle(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp idle(other), do: {:error, "idle is milliseconds or :infinity, got: #{inspect(other)}"}

  defp positive(n, _key) when is_integer(n) and n > 0, do: {:ok, n}
  defp positive(other, key), do: {:error, "#{key} is a positive integer, got: #{inspect(other)}"}

  defp optional_positive(nil, _key), do: {:ok, nil}
  defp optional_positive(n, key), do: positive(n, key)

  defp memory_threshold(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp memory_threshold(other),
    do: {:error, "memory_threshold is a number of bytes, got: #{inspect(other)}"}

  @doc """
  Checks a `mode:` given to an instance or a store: `nil` (no opinion),
  or `"auto"`, `"memory"` or `"disk"`, as a string or an atom.

      iex> Aerotow.Options.mode(:memory)
      {:ok, "memory"}
  """
  @spec mode(term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def mode(nil), do: {:ok, nil}
  def mode(mode) when mode in [:auto, :memory, :disk], do: {:ok, Atom.to_string(mode)}
  def mode(mode) when mode in ["auto", "memory", "disk"], do: {:ok, mode}

  def mode(other),
    do: {:error, "mode is \"auto\", \"memory\" or \"disk\", got: #{inspect(other)}"}

  @doc """
  Checks a `hot:` given to an instance or a store: `nil` (no opinion), or
  the bytes of hot set to keep; `0` is no hot set.
  """
  @spec hot(term()) :: {:ok, non_neg_integer() | nil} | {:error, String.t()}
  def hot(nil), do: {:ok, nil}
  def hot(n) when is_integer(n) and n >= 0, do: {:ok, n}
  def hot(other), do: {:error, "hot is a number of bytes or nil, got: #{inspect(other)}"}

  defp default_store(nil, _stores), do: {:ok, nil}

  defp default_store(name, stores) when is_binary(name) do
    if Enum.any?(stores, &(&1.name == name)),
      do: {:ok, name},
      else: {:error, "default_store #{inspect(name)} is not one of the stores given"}
  end

  defp default_store(other, _stores),
    do: {:error, "default_store is a store's name, got: #{inspect(other)}"}

  @doc "The node name written into flight records: this node's, when it is distributed."
  @spec node_name() :: String.t() | nil
  def node_name, do: if(Node.alive?(), do: Atom.to_string(node()))
end
