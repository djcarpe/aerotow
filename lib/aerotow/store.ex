defmodule Aerotow.Store do
  @moduledoc """
  A place gliders are kept.

  | kind | url | what is there |
  |---|---|---|
  | `:file` | a directory, with `kind: :file` | live databases, `<root>/<ref>.gldb`, opened where they lie |
  | `:dir` | a directory | replicas, in the layout of `Aerotow.Store.Layout` |
  | `:s3` | `s3://bucket/prefix` | the same, in a bucket |
  | `:peer` | `http://` or `https://` | another aerotow, which answers for its own gliders |

  `config` belongs to the module in `mod` and may hold credentials. `public/1`
  is what may be shown, logged, written to the catalog or sent to a peer.
  """

  @enforce_keys [:name, :kind, :url, :mod]
  defstruct name: nil,
            kind: nil,
            url: nil,
            mod: nil,
            config: %{},
            cas: nil,
            single_writer: false

  @type kind :: :file | :dir | :s3 | :peer

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          url: String.t(),
          mod: module(),
          config: map(),
          cas: boolean() | nil,
          single_writer: boolean()
        }

  @doc """
  The store without anything secret: its name, kind, url and whether
  exclusive writes hold there. Any `user:password@` in the url is removed.
  """
  @spec public(t()) :: %{name: String.t(), kind: kind(), url: String.t(), cas: boolean() | nil}
  def public(%__MODULE__{} = store) do
    %{name: store.name, kind: store.kind, url: strip_userinfo(store.url), cas: store.cas}
  end

  @doc "Whether the store holds replicas as objects (`:dir`, `:s3`), and so has flights."
  @spec objects?(t()) :: boolean()
  def objects?(%__MODULE__{kind: kind}), do: kind in [:dir, :s3]

  defp strip_userinfo(url) do
    case URI.parse(url) do
      %URI{userinfo: info} = uri when is_binary(info) -> URI.to_string(%{uri | userinfo: nil})
      _ -> url
    end
  end
end
