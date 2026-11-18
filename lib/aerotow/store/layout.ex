defmodule Aerotow.Store.Layout do
  @moduledoc """
  Where things are in a `dir` or `s3` store. Keys are relative to the store's
  root and always use `/`.

      aerotow.json                                 the store's marker
      cards/<ref>.json                             a glider's card
      gliders/<ref>/_flights/<n>.json              the record of flight n (the lease)
      gliders/<ref>/_flights/<n>/…                 what flight n shipped: glider's replica layout

  `<n>` is ten decimal digits. A ref segment cannot start with `_`, so
  `_flights` can never be part of a ref and the gliders `a` and `a/b` never
  share a key: `gliders/a/_flights/…` and `gliders/a/b/_flights/…`.

  Every function here takes a ref that `Aerotow.Ref.parse/1` has accepted.
  """

  alias Aerotow.Ref

  @format 1
  @digits 10
  @max_flight 9_999_999_999

  @doc "The layout's version, written in the marker."
  @spec format() :: pos_integer()
  def format, do: @format

  @doc "The highest flight number a record's name can hold."
  @spec max_flight() :: pos_integer()
  def max_flight, do: @max_flight

  @doc "The store's marker: `{format, id, created_at}`."
  @spec marker() :: String.t()
  def marker, do: "aerotow.json"

  @doc "The prefix every card is under."
  @spec cards_prefix() :: String.t()
  def cards_prefix, do: "cards/"

  @doc """
  The key of a glider's card.

      iex> Aerotow.Store.Layout.card("engineering/code")
      "cards/engineering/code.json"
  """
  @spec card(Ref.t()) :: String.t()
  def card(ref) when is_binary(ref), do: "cards/" <> ref <> ".json"

  @doc """
  The ref a card key belongs to, when the key is a card's and the ref in it is
  one.

      iex> Aerotow.Store.Layout.ref_of_card("cards/engineering/code.json")
      {:ok, "engineering/code"}

      iex> Aerotow.Store.Layout.ref_of_card("cards/../x.json")
      :error
  """
  @spec ref_of_card(String.t()) :: {:ok, Ref.t()} | :error
  def ref_of_card("cards/" <> rest) do
    with true <- String.ends_with?(rest, ".json"),
         {:ok, ref} <- Ref.parse(binary_part(rest, 0, byte_size(rest) - 5)) do
      {:ok, ref}
    else
      _ -> :error
    end
  end

  def ref_of_card(_), do: :error

  @doc """
  The prefix a glider's flights are under. Listing it with a delimiter
  returns the records (`<n>.json`) and the flights' directories (`<n>/`), and
  none of what is inside them.

      iex> Aerotow.Store.Layout.flights_prefix("engineering/code")
      "gliders/engineering/code/_flights/"
  """
  @spec flights_prefix(Ref.t()) :: String.t()
  def flights_prefix(ref) when is_binary(ref), do: "gliders/" <> ref <> "/_flights/"

  @doc """
  The key of a flight's record.

      iex> Aerotow.Store.Layout.flight_record("engineering/code", 7)
      "gliders/engineering/code/_flights/0000000007.json"
  """
  @spec flight_record(Ref.t(), pos_integer()) :: String.t()
  def flight_record(ref, n), do: flights_prefix(ref) <> pad(n) <> ".json"

  @doc """
  The prefix a flight ships under, with no trailing slash: what
  `Glider.Replication` takes as the replica.

      iex> Aerotow.Store.Layout.flight_data("engineering/code", 7)
      "gliders/engineering/code/_flights/0000000007"
  """
  @spec flight_data(Ref.t(), pos_integer()) :: String.t()
  def flight_data(ref, n), do: flights_prefix(ref) <> pad(n)

  @doc """
  The flight number in a record's key, when the key is a record of `ref`.

      iex> Aerotow.Store.Layout.flight_of_record("engineering/code", "gliders/engineering/code/_flights/0000000007.json")
      {:ok, 7}

      iex> Aerotow.Store.Layout.flight_of_record("engineering", "gliders/engineering/code/_flights/0000000007.json")
      :error
  """
  @spec flight_of_record(Ref.t(), String.t()) :: {:ok, pos_integer()} | :error
  def flight_of_record(ref, key) when is_binary(key) do
    prefix = flights_prefix(ref)

    with true <- String.starts_with?(key, prefix),
         <<digits::binary-size(@digits), ".json">> <-
           binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix)),
         {n, ""} when n > 0 <- Integer.parse(digits) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp pad(n) when is_integer(n) and n > 0 and n <= @max_flight,
    do: n |> Integer.to_string() |> String.pad_leading(@digits, "0")
end
