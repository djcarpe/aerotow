defmodule Aerotow.Store.File do
  @moduledoc """
  A store of live databases in a directory: the glider `engineering/code` is
  the file `<root>/engineering/code.gldb`, opened where it lies, and its card
  is `<root>/engineering/code.card.json` beside it.

  Glider keeps its own files beside a database: `<ref>.gldb-wal/`,
  `-data/`, `-stream/`, `-tmp/` and `<ref>.gldb.lock`. With the database and
  the card they are the glider, and `purge/2` removes exactly those. A ref
  segment never contains `.gldb`, so none of these names can be another
  glider's.

  A `.gldb` file with no card beside it is not a glider aerotow knows yet:
  `list_cards/1` lists cards, at any depth. Cards are written the way a `dir`
  store writes objects (`Aerotow.Store.Dir`): whole, under their name in one
  step. Nothing here follows a symbolic link.

  These functions are called through `Aerotow.Store` (`Aerotow.Store.read_card/2`
  and the rest), which also checks that a card names the ref it was read as.
  """

  alias Aerotow.{Card, Ref, Store}
  alias Aerotow.Store.Dir

  @card ".card.json"
  @glider ~w(.gldb .gldb-wal .gldb-data .gldb-stream .gldb-tmp .gldb.lock)
  @max_segments 8

  @doc """
  Checks the directory and returns the store's config, `%{root: path}`. A
  directory that does not exist is created; a path that is a file is an
  error.
  """
  @spec init(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def init(name, url, opts), do: Dir.init(name, url, opts)

  @doc """
  Where a glider's database is: `<root>/<ref>.gldb`, inside the root for
  every ref. Raises `ArgumentError` for what is not a ref.
  """
  @spec path(Store.t(), Ref.t()) :: Path.t()
  def path(%Store{config: %{root: root}}, ref), do: Path.join(root, Ref.parse!(ref) <> ".gldb")

  @doc "A glider's card, decoded, or `{:error, :not_found}`."
  @spec read_card(Store.t(), Ref.t()) :: {:ok, Card.t()} | {:error, :not_found | String.t()}
  def read_card(%Store{config: config}, ref) do
    with {:ok, ref} <- Ref.parse(ref) do
      key = ref <> @card

      case Dir.get(config, key) do
        {:ok, json} -> decode(json, key)
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode(json, key) do
    case Card.decode(json) do
      {:ok, card} -> {:ok, card}
      {:error, reason} -> {:error, "#{key}: #{reason}"}
    end
  end

  @doc "Writes a glider's card beside its database, replacing the one there."
  @spec write_card(Store.t(), Card.t()) :: :ok | {:error, String.t()}
  def write_card(%Store{config: config}, %Card{} = card) do
    with {:ok, ref} <- Ref.parse(card.ref) do
      Dir.put(config, ref <> @card, Card.encode(card), [])
    end
  end

  @doc "Deletes a glider's card, and nothing else. Deleting one that is not there is `:ok`."
  @spec delete_card(Store.t(), Ref.t()) :: :ok | {:error, String.t()}
  def delete_card(%Store{config: %{root: root}}, ref) do
    with {:ok, ref} <- Ref.parse(ref) do
      case home(root, ref) do
        {:ok, dir} -> remove(Path.join(dir, Ref.name(ref) <> @card), ref <> @card)
        :none -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp remove(path, shown) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, "cannot delete #{shown}: #{posix(reason)}"}
        end

      {:ok, _not_a_file} ->
        :ok

      {:error, reason} when reason in [:enoent, :enotdir] ->
        :ok

      {:error, reason} ->
        {:error, "cannot delete #{shown}: #{posix(reason)}"}
    end
  end

  @doc """
  Every card in the store, at any depth: its ref and a version that changes
  when the card's bytes do. A file whose name is not a card's, or whose ref
  does not parse, is skipped, and so is everything under a directory that
  cannot be part of a ref (a glider's own `.gldb-…` directories among them).
  """
  @spec list_cards(Store.t()) ::
          {:ok, [%{ref: Ref.t(), version: String.t()}]} | {:error, String.t()}
  def list_cards(%Store{config: %{root: root}}) do
    with {:ok, cards} <- cards_in(root, "", 1), do: {:ok, Enum.sort_by(cards, & &1.ref)}
  end

  # The directory `depth` levels down holds the cards of refs of `depth`
  # segments.
  defp cards_in(dir, namespace, depth) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
          case entry(dir, namespace, name, depth) do
            {:ok, found} -> {:cont, {:ok, found ++ acc}}
            error -> {:halt, error}
          end
        end)

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot list #{shown_dir(namespace)}: #{posix(reason)}"}
    end
  end

  defp entry(_dir, _namespace, "." <> _hidden, _depth), do: {:ok, []}

  defp entry(dir, namespace, name, depth) do
    case File.lstat(Path.join(dir, name), time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, card_entry(namespace, name, stat)}

      {:ok, %File.Stat{type: :directory}} when depth < @max_segments ->
        if Ref.valid?(name),
          do: cards_in(Path.join(dir, name), namespace <> name <> "/", depth + 1),
          else: {:ok, []}

      {:ok, _link_or_other} ->
        {:ok, []}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot list #{namespace <> name}: #{posix(reason)}"}
    end
  end

  defp card_entry(namespace, name, stat) do
    with true <- String.ends_with?(name, @card),
         {:ok, ref} <- Ref.parse(namespace <> String.replace_suffix(name, @card, "")) do
      [%{ref: ref, version: Dir.version(stat)}]
    else
      _ -> []
    end
  end

  @doc """
  Deletes a glider: its card, then its database and the files glider keeps
  beside it (`-wal/`, `-data/`, `-stream/`, `-tmp/`, `.lock`), and nothing
  else. Nothing may have the database open while it is purged.
  """
  @spec purge(Store.t(), Ref.t()) :: :ok | {:error, String.t()}
  def purge(%Store{config: %{root: root}}, ref) do
    with {:ok, ref} <- Ref.parse(ref) do
      case home(root, ref) do
        {:ok, dir} -> remove_glider(dir, ref)
        :none -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp remove_glider(dir, ref) do
    name = Ref.name(ref)

    with :ok <- remove(Path.join(dir, name <> @card), ref <> @card) do
      Enum.reduce_while(@glider, :ok, fn suffix, :ok ->
        # rm_rf removes a symbolic link itself, never what it points to.
        case File.rm_rf(Path.join(dir, name <> suffix)) do
          {:ok, _} ->
            {:cont, :ok}

          {:error, reason, _file} ->
            {:halt, {:error, "cannot delete #{ref <> suffix}: #{posix(reason)}"}}
        end
      end)
    end
  end

  # The directory a ref's files are in, when every directory on the way is a
  # directory and not a symbolic link; `:none` when there is no such
  # directory.
  defp home(root, ref) do
    ref
    |> Ref.segments()
    |> Enum.drop(-1)
    |> Enum.reduce_while({:ok, root}, fn segment, {:ok, dir} ->
      path = Path.join(dir, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, path}}
        {:ok, _file_or_link} -> {:halt, :none}
        {:error, reason} when reason in [:enoent, :enotdir] -> {:halt, :none}
        {:error, reason} -> {:halt, {:error, "cannot reach #{ref}: #{posix(reason)}"}}
      end
    end)
  end

  defp shown_dir(""), do: "the store's root"
  defp shown_dir(namespace), do: namespace

  defp posix(reason) when is_atom(reason), do: reason |> :file.format_error() |> List.to_string()
  defp posix(reason), do: inspect(reason)
end
