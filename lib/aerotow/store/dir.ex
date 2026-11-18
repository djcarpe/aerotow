defmodule Aerotow.Store.Dir do
  @moduledoc """
  An object store in a directory: the object `cards/a/b.json` is the file
  `<root>/cards/a/b.json`. It is what a `dir` store is, in the layout an S3
  bucket has, so glider's own replication reads and writes it as a replica
  (`replica/2`).

  ## Writing

  A put writes the whole body to a new file in `<root>/.aerotow-tmp/`, syncs
  it, and then gives it its key in one step:

    * a plain put renames it over the key (`rename(2)`), which replaces
      whatever was there at once;
    * an exclusive put links it at the key (`link(2)`), which fails if
      anything is there already, and then removes the temporary name.

  So a key always names a whole file. A reader that opened the old one reads
  the old one to the end; a reader that opens the key afterwards reads the
  new one; and a key that exists never goes missing in between.

  `link(2)` is atomic and refuses a name that exists on every POSIX
  filesystem with hard links: ext4, XFS, btrfs, tmpfs, ZFS, NFS. Over NFS the
  reply to a link that was made can be lost and the retried call then finds
  the name taken; the temporary file's link count tells that case apart. A
  filesystem without hard links (FAT, and some FUSE and SMB mounts) cannot
  make an exclusive put: there `put/4` with `exclusive: true` is an error,
  and `probe/1` says `cas: false`.

  ## Durability

  The temporary file is synced (`fsync`) before it gets its name, so a name
  never points at content that is not on disk, and synced again after the
  rename or link, which on ext4, XFS and btrfs commits the new name with it.
  Erlang cannot open a directory, so the directory itself is not synced. A
  put that returned `:ok` survives a crash of the BEAM, and on those
  filesystems a crash of the machine. A delete is not synced: a power cut
  can bring a deleted object back.

  ## What is not an object

  Names that start with `.` are the store's own (`.aerotow-tmp`) or nobody's
  (`.nfs…`, `.snapshot`): a key with such a segment is refused, and listings
  skip them. A symbolic link is never followed: a key whose path passes
  through one, or ends at one, is not an object (`get/2` says `:not_found`,
  `delete/2` leaves it be), and `put/4` refuses to write through one. A
  directory is not an object either. Once the last object under one is
  deleted the directory is removed, so it stops appearing in listings, as a
  prefix in a bucket does; a directory with no object anywhere under it is
  not listed as a prefix.

  ## Versions

  An object's version is its file's modification time, size and inode
  (`version/1`). Every put makes a new file, so a new inode, and a plain put
  gives it a modification time later than that of the file it replaces: a
  filesystem that hands out an inode it has just freed, within one second,
  still gives a new version. An object nobody writes keeps its version.
  """

  @behaviour Aerotow.Store.Objects

  alias Aerotow.Store

  @staging ".aerotow-tmp"
  @attempts 8
  @no_links [:eperm, :enotsup, :eopnotsupp]

  @impl true
  def init(_name, url, _opts) when is_binary(url) do
    case String.replace_prefix(url, "file://", "") do
      "" -> {:error, "a directory store needs a directory"}
      path -> root(Path.expand(path))
    end
  end

  defp root(root) do
    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, %{root: root}}

      {:ok, _} ->
        {:error, "#{root} is a file, not a directory"}

      {:error, :enoent} ->
        case File.mkdir_p(root) do
          :ok -> {:ok, %{root: root}}
          {:error, reason} -> {:error, "cannot create #{root}: #{posix(reason)}"}
        end

      {:error, reason} ->
        {:error, "cannot use #{root}: #{posix(reason)}"}
    end
  end

  # ------------------------------------------------------------------ reading

  @impl true
  def get(%{root: root}, key) do
    with :ok <- check_key(key) do
      case locate(root, key) do
        {:ok, path, %File.Stat{type: :regular}} -> read(path, key, @attempts)
        {:ok, _path, _not_a_file} -> {:error, :not_found}
        :none -> {:error, :not_found}
        {:error, _} = error -> error
      end
    end
  end

  defp read(path, key, attempts) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} when reason in [:enoent, :enotdir, :eisdir] ->
        {:error, :not_found}

      # NFS: the file this client had looked up was replaced on the server.
      {:error, :estale} when attempts > 1 ->
        read(path, key, attempts - 1)

      {:error, reason} ->
        {:error, "cannot read #{key}: #{posix(reason)}"}
    end
  end

  # ------------------------------------------------------------------ writing

  @impl true
  def put(%{root: root}, key, body, opts) do
    with :ok <- check_key(key) do
      if Keyword.get(opts, :exclusive, false),
        do: put_new(root, key, body),
        else: write(root, key, body, &replace/4)
    end
  end

  # An object already there is :exists without writing anything.
  defp put_new(root, key, body) do
    case locate(root, key) do
      {:ok, _path, %File.Stat{type: :regular}} -> {:error, :exists}
      {:ok, _path, stat} -> {:error, occupied(key, stat)}
      _ -> write(root, key, body, &link/4)
    end
  end

  defp occupied(key, %File.Stat{type: :directory}),
    do: "cannot write #{key}: a directory is there"

  defp occupied(key, %File.Stat{type: :symlink}),
    do: "cannot write #{key}: a symbolic link is there, which this store does not follow"

  defp occupied(key, %File.Stat{type: type}), do: "cannot write #{key}: a #{type} file is there"

  defp write(root, key, body, publish) do
    with {:ok, tmp, fd} <- temporary(root, key, body, 2) do
      try do
        publish.(root, key, tmp, fd)
      after
        _ = :file.close(fd)
        _ = File.rm(tmp)
      end
    end
  end

  defp temporary(root, key, body, tries) do
    staging = Path.join(root, @staging)
    tmp = Path.join(staging, random_name())

    with :ok <- staging(staging) do
      case :file.open(tmp, [:write, :exclusive, :raw, :binary]) do
        {:ok, fd} ->
          case :file.write(fd, body) do
            :ok ->
              {:ok, tmp, fd}

            {:error, reason} ->
              _ = :file.close(fd)
              _ = File.rm(tmp)
              {:error, "cannot write #{key}: #{posix(reason)}"}
          end

        {:error, :enoent} when tries > 1 ->
          temporary(root, key, body, tries - 1)

        {:error, reason} ->
          {:error, "cannot write #{key}: #{posix(reason)}"}
      end
    end
  end

  defp staging(staging) do
    case File.mkdir(staging) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(staging) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, _} -> {:error, "#{staging} is not a directory, and puts are written there"}
          {:error, reason} -> {:error, "cannot use #{staging}: #{posix(reason)}"}
        end

      {:error, reason} ->
        {:error, "cannot write in #{Path.dirname(staging)}: #{posix(reason)}"}
    end
  end

  # A plain put: the new file is renamed over whatever is at the key.
  defp replace(root, key, tmp, fd) do
    path = Path.join(root, key)

    with :ok <- later(tmp, path, key),
         :ok <- sync(fd, key) do
      case place(root, key, fn -> File.rename(tmp, path) end, @attempts) do
        :ok -> sync(fd, key)
        {:error, reason} -> {:error, cannot_write(key, reason)}
      end
    end
  end

  # An exclusive put: the new file is linked at the key, which fails if
  # anything is there.
  defp link(root, key, tmp, fd) do
    path = Path.join(root, key)

    with :ok <- sync(fd, key) do
      case place(root, key, fn -> File.ln(tmp, path) end, @attempts) do
        :ok ->
          claimed(tmp, fd, key)

        # Over NFS a link whose reply was lost is retried and finds the name
        # taken, by this very file, which then has two names.
        {:error, :eexist} ->
          if links(tmp) == 2, do: claimed(tmp, fd, key), else: taken(path, key)

        {:error, reason} when reason in @no_links ->
          {:error,
           "cannot write #{key} exclusively: this filesystem makes no hard links (#{posix(reason)})"}

        {:error, reason} ->
          {:error, cannot_write(key, reason)}
      end
    end
  end

  defp claimed(tmp, fd, key) do
    _ = File.rm(tmp)
    sync(fd, key)
  end

  defp links(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{links: n}} -> n
      {:error, _} -> 0
    end
  end

  # What made the link fail. One that is gone again was there when the link
  # was refused, so the answer stands.
  defp taken(path, key) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:error, :exists}
      {:ok, stat} -> {:error, occupied(key, stat)}
      {:error, _} -> {:error, :exists}
    end
  end

  # A new version must differ from every earlier one. The file is new, but a
  # filesystem may give it an inode it freed a moment ago, and Erlang reads
  # modification times in whole seconds: so the new file is made a second
  # newer than the one it replaces, when it is not already.
  defp later(tmp, path, key) do
    with {:ok, %File.Stat{mtime: mine}} <- File.lstat(tmp, time: :posix),
         :ok <- touch_after(tmp, File.lstat(path, time: :posix), mine) do
      :ok
    else
      {:error, reason} -> {:error, cannot_write(key, reason)}
    end
  end

  defp touch_after(tmp, {:ok, %File.Stat{type: :regular, mtime: theirs}}, mine)
       when theirs >= mine,
       do: File.touch(tmp, theirs + 1)

  defp touch_after(_tmp, _current, _mine), do: :ok

  defp sync(fd, key) do
    case :file.sync(fd) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot sync #{key}: #{posix(reason)}"}
    end
  end

  # Makes the directories on the way to the key, then renames or links. A
  # directory that a delete removed as empty a moment ago is made again.
  defp place(root, key, step, attempts) do
    result =
      case parents(root, key) do
        :ok -> step.()
        error -> error
      end

    case result do
      {:error, :enoent} when attempts > 1 -> place(root, key, step, attempts - 1)
      result -> result
    end
  end

  defp parents(root, key) do
    {dirs, _name} = key |> :binary.split("/", [:global]) |> Enum.split(-1)

    dirs
    |> Enum.reduce_while({:ok, root, ""}, fn segment, {:ok, dir, shown} ->
      path = Path.join(dir, segment)
      shown = shown <> segment

      case make_dir(path, shown) do
        :ok -> {:cont, {:ok, path, shown <> "/"}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _dir, _shown} -> :ok
      error -> error
    end
  end

  defp make_dir(path, shown) do
    case File.mkdir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            :ok

          {:ok, %File.Stat{type: :symlink}} ->
            {:error, "#{shown} is a symbolic link, which this store does not follow"}

          {:ok, _} ->
            {:error, "#{shown} is an object, so nothing can be under it"}

          {:error, :enoent} ->
            {:error, :enoent}

          {:error, reason} ->
            {:error, "cannot look at #{shown}: #{posix(reason)}"}
        end

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, "cannot make #{shown}: #{posix(reason)}"}
    end
  end

  defp cannot_write(key, :eisdir), do: "cannot write #{key}: a directory is there"
  defp cannot_write(_key, reason) when is_binary(reason), do: reason
  defp cannot_write(key, reason), do: "cannot write #{key}: #{posix(reason)}"

  # ------------------------------------------------------------------ deleting

  @impl true
  def delete(%{root: root}, key) do
    with :ok <- check_key(key) do
      case locate(root, key) do
        {:ok, path, %File.Stat{type: :regular}} -> remove(root, path, key)
        {:ok, _path, _not_a_file} -> :ok
        :none -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp remove(root, path, key) do
    case File.rm(path) do
      :ok -> prune(root, Path.dirname(path))
      {:error, reason} when reason in [:enoent, :enotdir] -> :ok
      {:error, reason} -> {:error, "cannot delete #{key}: #{posix(reason)}"}
    end
  end

  # Removes the directories a delete left empty, up to the root. rmdir
  # refuses a directory that is not empty, so one somebody has just written
  # into stays.
  defp prune(root, dir) do
    if dir != root and String.starts_with?(dir, root <> "/") and File.rmdir(dir) == :ok,
      do: prune(root, Path.dirname(dir)),
      else: :ok
  end

  # ------------------------------------------------------------------ listing

  @impl true
  def list(%{root: root}, prefix, opts) do
    with :ok <- check_prefix(prefix) do
      {dir, start} = split(prefix)

      case down(root, dir_segments(dir), prefix) do
        {:ok, path} -> scan(path, dir, start, Keyword.get(opts, :delimiter, false))
        :none -> {:ok, %{objects: [], prefixes: []}}
        {:error, _} = error -> error
      end
    end
  end

  # "cards/a" is the entries of cards/ whose names start with "a".
  defp split(prefix) do
    case :binary.matches(prefix, "/") do
      [] ->
        {"", prefix}

      matches ->
        {at, 1} = List.last(matches)
        {binary_part(prefix, 0, at + 1), binary_part(prefix, at + 1, byte_size(prefix) - at - 1)}
    end
  end

  defp dir_segments(""), do: []

  defp dir_segments(dir),
    do: dir |> binary_part(0, byte_size(dir) - 1) |> :binary.split("/", [:global])

  defp scan(path, dir, start, delimiter) do
    with {:ok, entries} <- entries(path, dir) do
      entries = Enum.filter(entries, fn {name, _stat} -> String.starts_with?(name, start) end)
      if delimiter, do: shallow(path, dir, entries), else: deep(path, dir, entries)
    end
  end

  defp shallow(path, dir, entries) do
    entries
    |> Enum.reduce_while({:ok, [], []}, fn
      {name, %File.Stat{type: :regular} = stat}, {:ok, objects, prefixes} ->
        {:cont, {:ok, [object(dir <> name, stat) | objects], prefixes}}

      {name, %File.Stat{type: :directory}}, {:ok, objects, prefixes} ->
        sub = dir <> name <> "/"

        case holds_object?(Path.join(path, name), sub) do
          {:ok, true} -> {:cont, {:ok, objects, [sub | prefixes]}}
          {:ok, false} -> {:cont, {:ok, objects, prefixes}}
          error -> {:halt, error}
        end

      _link_or_other, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, objects, prefixes} ->
        {:ok, %{objects: Enum.sort_by(objects, & &1.key), prefixes: Enum.sort(prefixes)}}

      error ->
        error
    end
  end

  defp deep(path, dir, entries) do
    with {:ok, objects} <- walk(path, dir, entries, []) do
      {:ok, %{objects: Enum.sort_by(objects, & &1.key), prefixes: []}}
    end
  end

  defp walk(path, dir, entries, acc) do
    Enum.reduce_while(entries, {:ok, acc}, fn
      {name, %File.Stat{type: :regular} = stat}, {:ok, acc} ->
        {:cont, {:ok, [object(dir <> name, stat) | acc]}}

      {name, %File.Stat{type: :directory}}, {:ok, acc} ->
        sub = Path.join(path, name)
        sub_dir = dir <> name <> "/"

        with {:ok, children} <- entries(sub, sub_dir),
             {:ok, acc} <- walk(sub, sub_dir, children, acc) do
          {:cont, {:ok, acc}}
        else
          error -> {:halt, error}
        end

      _link_or_other, acc ->
        {:cont, acc}
    end)
  end

  # The visible entries of a directory, with what each is. One that is gone
  # by the time it is looked at was deleted meanwhile, and is not listed.
  defp entries(path, dir) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.reject(&hidden?/1)
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          case File.lstat(Path.join(path, name), time: :posix) do
            {:ok, stat} -> {:cont, {:ok, [{name, stat} | acc]}}
            {:error, reason} when reason in [:enoent, :enotdir] -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, "cannot list #{dir <> name}: #{posix(reason)}"}}
          end
        end)

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot list #{shown_dir(dir)}: #{posix(reason)}"}
    end
  end

  # Whether there is an object anywhere under a directory; it stops at the
  # first one it finds.
  defp holds_object?(path, dir) do
    case File.ls(path) do
      {:ok, names} -> first_object(path, dir, Enum.reject(names, &hidden?/1), [])
      {:error, reason} when reason in [:enoent, :enotdir] -> {:ok, false}
      {:error, reason} -> {:error, "cannot list #{dir}: #{posix(reason)}"}
    end
  end

  defp first_object(_path, _dir, [], subdirs) do
    Enum.reduce_while(subdirs, {:ok, false}, fn {sub, sub_dir}, _ ->
      case holds_object?(sub, sub_dir) do
        {:ok, false} -> {:cont, {:ok, false}}
        other -> {:halt, other}
      end
    end)
  end

  defp first_object(path, dir, [name | rest], subdirs) do
    sub = Path.join(path, name)

    case File.lstat(sub) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, true}

      {:ok, %File.Stat{type: :directory}} ->
        first_object(path, dir, rest, [{sub, dir <> name <> "/"} | subdirs])

      {:ok, _link_or_other} ->
        first_object(path, dir, rest, subdirs)

      {:error, reason} when reason in [:enoent, :enotdir] ->
        first_object(path, dir, rest, subdirs)

      {:error, reason} ->
        {:error, "cannot list #{dir <> name}: #{posix(reason)}"}
    end
  end

  defp object(key, %File.Stat{size: size} = stat),
    do: %{key: key, size: size, version: version(stat)}

  defp shown_dir(""), do: "the store's root"
  defp shown_dir(dir), do: dir

  @doc """
  An object's version, from its file's status read with `time: :posix`: the
  modification time, size and inode.

      iex> Aerotow.Store.Dir.version(%File.Stat{mtime: 1763400000, size: 120, inode: 77})
      "1763400000-120-77"
  """
  @spec version(File.Stat.t()) :: String.t()
  def version(%File.Stat{mtime: mtime, size: size, inode: inode}) when is_integer(mtime),
    do: "#{mtime}-#{size}-#{inode}"

  # ------------------------------------------------------------------ replicas

  @impl true
  def replica(%{root: root}, prefix) do
    case check_key(prefix) do
      :ok -> {Path.join(root, prefix), []}
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # ------------------------------------------------------------------ probing

  @impl true
  def probe(%{root: root} = config) do
    case hard_links(root) do
      :ok ->
        Store.probe_cas(%{
          put: &put(config, &1, &2, &3),
          get: &get(config, &1),
          delete: &delete(config, &1)
        })

      :none ->
        {:ok, %{cas: false}}

      {:error, _} = error ->
        error
    end
  end

  # Whether this filesystem makes hard links, which an exclusive put is.
  defp hard_links(root) do
    staging = Path.join(root, @staging)
    a = Path.join(staging, random_name())
    b = Path.join(staging, random_name())

    with :ok <- staging(staging) do
      result =
        case File.write(a, "", [:exclusive]) do
          :ok -> try_link(a, b, staging)
          {:error, reason} -> {:error, "cannot write in #{staging}: #{posix(reason)}"}
        end

      _ = File.rm(a)
      _ = File.rm(b)
      result
    end
  end

  defp try_link(a, b, staging) do
    case File.ln(a, b) do
      :ok -> :ok
      {:error, reason} when reason in @no_links -> :none
      {:error, reason} -> {:error, "cannot make a link in #{staging}: #{posix(reason)}"}
    end
  end

  # ------------------------------------------------------------------ keys and paths

  defp check_key(key) do
    with :ok <- Store.check_key(key), do: unhidden(key, "key")
  end

  defp check_prefix(prefix) do
    with :ok <- Store.check_prefix(prefix), do: unhidden(prefix, "prefix")
  end

  defp unhidden(s, what) do
    if s |> :binary.split("/", [:global]) |> Enum.any?(&hidden?/1),
      do:
        {:error,
         "not a #{what} in a directory store: #{inspect(s)} has a segment starting with " <>
           "\".\", and such names are the store's own"},
      else: :ok
  end

  defp hidden?(name), do: String.starts_with?(name, ".")

  # Where `key` is, when every directory on the way to it is a directory and
  # not a symbolic link: its path and what is there. `:none` when nothing is.
  defp locate(root, key) do
    {dirs, [name]} = key |> :binary.split("/", [:global]) |> Enum.split(-1)

    with {:ok, dir} <- down(root, dirs, key) do
      path = Path.join(dir, name)

      case File.lstat(path, time: :posix) do
        {:ok, stat} -> {:ok, path, stat}
        {:error, reason} when reason in [:enoent, :enotdir] -> :none
        {:error, reason} -> {:error, "cannot reach #{key}: #{posix(reason)}"}
      end
    end
  end

  # The directory `segments` names under the root, when each one on the way
  # is a directory and not a symbolic link; `:none` when one is missing or is
  # something else.
  defp down(root, segments, what) do
    Enum.reduce_while(segments, {:ok, root}, fn segment, {:ok, dir} ->
      path = Path.join(dir, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, path}}
        {:ok, _file_or_link} -> {:halt, :none}
        {:error, reason} when reason in [:enoent, :enotdir] -> {:halt, :none}
        {:error, reason} -> {:halt, {:error, "cannot reach #{what}: #{posix(reason)}"}}
      end
    end)
  end

  defp random_name, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp posix(reason) when is_atom(reason), do: reason |> :file.format_error() |> List.to_string()
  defp posix(reason) when is_binary(reason), do: reason
  defp posix(reason), do: inspect(reason)
end
