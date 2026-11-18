# aerotow

One interface over many [glider](https://github.com/djcarpe/glider) graphs.

An aerotow is the powered aircraft that tows a glider into the air and lets it
go. Glider is one graph, in one file, with one writer. Aerotow is the layer
over many of them: it knows where each one is kept, launches it when somebody
needs it, and puts it back when they are done.

- **A catalog.** A graph of metadata, itself a glider: a node for every
  glider with what it holds, a node for every store, and edges for where each
  glider is kept and which gliders link to which. Finding a glider is a query
  over that graph.
- **Stores.** A directory of live files, a directory or an S3 bucket of
  replicas, or another aerotow reached over HTTP.
- **One interface.** A statement runs the same way wherever its glider is
  kept: restored from S3 if it is cold, run on the copy that is open, or
  forwarded to the aerotow that has it open.

Every glider stays an independent database with its own single writer.
Aerotow never merges two of them; it routes.

```elixir
children = [
  {Aerotow,
   name: MyApp.Aerotow,
   dir: "/var/lib/aerotow",
   stores: [
     {"assets", "s3://graphs/gliders", endpoint: "http://minio.internal:9000"},
     {"west", "https://west.example.com/aerotow", token: token}
   ],
   default_store: "assets"}
]

tow = MyApp.Aerotow

{:ok, _card} = Aerotow.create(tow, "engineering/code", description: "the code graph", tags: ["code"])
{:ok, 3} = Aerotow.run(tow, "engineering/code", ~S|CREATE (:Module {name:"Aerotow"})-[:CALLS]->(:Module {name:"Glider"})|)

# find: Cypher over the metadata
{:ok, %{rows: [["engineering/code", "assets"]]}} =
  Aerotow.find(tow, """
  MATCH (g:Glider)-[:HAS_LABEL]->(:Label {name: "Module"}), (g)-[:HOMED_IN]->(s:Store)
  RETURN g.ref, s.name
  """)

# interact: wherever it is
{:ok, result} = Aerotow.query(tow, "engineering/code", "MATCH (m:Module) RETURN m.name")
```

## Status

Built against [docs/DESIGN.md](docs/DESIGN.md), which is the contract: the
catalog's schema, the layout of a store, how a flight leases a glider, where
a statement runs, the protocol between aerotows, and what can go wrong.

What runs: instances over `file`, `dir`, `s3` and `peer` stores, with the
catalog, scans, flights (leases, shipping, landing), the whole interface of
the design's table, forwarding to the instance that holds a glider (over
Erlang distribution or HTTP through `Aerotow.Plug`), carrying a working copy
left behind into the next flight, orphans, and retention. Every row of the
design's "What can go wrong" table has a test.

Not yet: flying a glider in memory, or from disk with a hot set. The engine
has both (glider's in-memory replication and hot set); aerotow does not use
them yet.

## Build

```sh
mix deps.get
mix test
```

Building needs a Rust toolchain: the glider engine is linked in through
[glider_ex](https://github.com/djcarpe/glider_ex), a NIF.

## Licence

MIT. See [LICENSE](LICENSE).
