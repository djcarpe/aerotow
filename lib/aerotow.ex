defmodule Aerotow do
  @moduledoc """
  One interface over many [glider](https://github.com/djcarpe/glider) graphs.

  An aerotow is the powered aircraft that tows a glider into the air and lets
  it go. This library knows where each glider is kept, launches it when
  somebody needs it, and puts it back when they are done:

    * a **catalog**: a graph of metadata, itself a glider, with a node for
      every glider and every store. Finding a glider is a query over it
    * **stores**: a directory of live files, a directory or an S3 bucket of
      replicas, or another aerotow reached over HTTP
    * **one interface**: `query/5`, `run/5`, `context/3` do the same thing
      wherever a glider is kept

  Every glider stays an independent database with its own single writer.
  Aerotow never merges two of them; it routes.

  The design, and the rules the code is built against, are in
  [docs/DESIGN.md](docs/DESIGN.md).
  """
end
