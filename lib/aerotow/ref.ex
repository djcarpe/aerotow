defmodule Aerotow.Ref do
  @moduledoc """
  A glider's name: `engineering/code`, `public/site`.

      ref     = segment *( "/" segment )        1 to 8 segments, at most 255 bytes
      segment = [a-z0-9] *( [a-z0-9._-] )       at most 63 bytes, ends in a letter or digit,
                                                and never contains ".gldb"

  A ref becomes a file path in a directory and a key in a bucket, so
  `parse/1` is the only way a string from outside (an API call, a card, a
  peer) is allowed to become one. Lower case only: a ref means the same thing
  on a case-insensitive disk and in a bucket. A segment cannot start with `_`
  or `.`; names that do (`_flights`) are aerotow's own, which is what keeps
  the gliders `a` and `a/b` apart in a store.
  """

  @type t :: String.t()

  @max_bytes 255
  @max_segments 8
  @segment ~r/\A[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?\z/

  @doc """
  Checks a ref. Returns it unchanged, or says what is wrong with it.

      iex> Aerotow.Ref.parse("engineering/code")
      {:ok, "engineering/code"}

      iex> Aerotow.Ref.parse("../etc/passwd")
      {:error, "not a ref: \\"../etc/passwd\\" (segment \\"..\\" must be lower-case letters, digits, '.', '_' or '-', starting and ending with a letter or digit)"}
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(ref) when is_binary(ref) do
    segments = :binary.split(ref, "/", [:global])

    cond do
      ref == "" ->
        {:error, "not a ref: it is empty"}

      byte_size(ref) > @max_bytes ->
        {:error, "not a ref: longer than #{@max_bytes} bytes"}

      length(segments) > @max_segments ->
        {:error, "not a ref: #{inspect(ref)} has more than #{@max_segments} segments"}

      true ->
        case Enum.find(segments, &(not segment?(&1))) do
          nil -> {:ok, ref}
          bad -> {:error, "not a ref: #{inspect(ref)} (segment #{inspect(bad)} #{why(bad)})"}
        end
    end
  end

  def parse(other), do: {:error, "not a ref: expected a string, got #{inspect(other)}"}

  @doc "Like `parse/1`, raising `ArgumentError`."
  @spec parse!(term()) :: t()
  def parse!(ref) do
    case parse(ref) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "Whether `ref` is a ref."
  @spec valid?(term()) :: boolean()
  def valid?(ref), do: match?({:ok, _}, parse(ref))

  @doc "The segments of a ref that has been parsed."
  @spec segments(t()) :: [String.t()]
  def segments(ref), do: :binary.split(ref, "/", [:global])

  @doc """
  The last segment.

      iex> Aerotow.Ref.name("engineering/code")
      "code"
  """
  @spec name(t()) :: String.t()
  def name(ref), do: ref |> segments() |> List.last()

  @doc """
  Everything before the last segment, `""` for a ref of one segment.

      iex> Aerotow.Ref.namespace("acme/engineering/code")
      "acme/engineering"
  """
  @spec namespace(t()) :: String.t()
  def namespace(ref) do
    ref |> segments() |> Enum.drop(-1) |> Enum.join("/")
  end

  @doc """
  Whether `ref` is `prefix` or lies under it, on a segment boundary.

      iex> Aerotow.Ref.under?("engineering/code", "engineering")
      true

      iex> Aerotow.Ref.under?("engineering-old/code", "engineering")
      false
  """
  @spec under?(t(), String.t()) :: boolean()
  def under?(_ref, ""), do: true

  def under?(ref, prefix) do
    prefix = String.trim_trailing(prefix, "/")
    ref == prefix or String.starts_with?(ref, prefix <> "/")
  end

  defp segment?(s), do: Regex.match?(@segment, s) and not String.contains?(s, ".gldb")

  defp why(""), do: "is empty"

  defp why(s) do
    cond do
      byte_size(s) > 63 ->
        "is longer than 63 bytes"

      String.contains?(s, ".gldb") ->
        "contains \".gldb\", which names a glider's own files"

      true ->
        "must be lower-case letters, digits, '.', '_' or '-', starting and ending with a letter or digit"
    end
  end
end
