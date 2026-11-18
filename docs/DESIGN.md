# Aerotow: design

An aerotow is the powered aircraft that tows a glider into the air and lets it
go. This library does that for [glider](https://github.com/djcarpe/glider)
graphs: it knows where each one is kept, launches it when somebody needs it,
and puts it back when they are done.

This document is the contract the code is built against. Rules that tests
must hold are numbered (R1, R2, …).

## What it is

Glider is one graph, in one file, with one writer. Aerotow is the layer over
many of them:

- **A catalog.** A graph of metadata, itself a glider: one node per glider
  with what it holds (labels, relationship types, counts, size, tags), one
  node per store, and edges for where each glider is kept and which gliders
  link to which. Finding a glider is a query over that graph.
- **Stores.** The places gliders are kept: a directory of live files, a
  directory or an S3 bucket of replicas, or another aerotow reached over HTTP
  (another deployment).
- **One interface.** `Aerotow.query(tow, "engineering/code", "MATCH …")` does
  the same thing wherever that glider is kept. Aerotow restores it from S3 if
  it is cold, runs the statement on the copy that is open, or forwards it to
  the aerotow that has it open.

Every glider stays an independent database: its own lineage, its own single
writer, its own place. Aerotow never merges two gliders and never runs one
statement across two of them. It routes.

```
                      Aerotow.find / query / run / context
                                      │
        ┌─────────────────────────────┼──────────────────────────────┐
        │ catalog (a glider)          │ flights (gliders open here)  │
        │ (:Glider)-[:HOMED_IN]->     │   engineering/code   flight 7│
        │ (:Store), HAS_LABEL, …      │   public/site        flight 2│
        └──────────────┬──────────────┴───────────┬──────────────────┘
                       │ cards                    │ base + log, leases
        ┌──────────────┼──────────────────┬───────┴─────────┬──────────────┐
        │ file store   │ dir store        │ s3 store        │ peer store   │
        │ live .gldb   │ replicas on a    │ replicas in a   │ another      │
        │ files        │ mounted disk     │ bucket          │ aerotow      │
        └──────────────┴──────────────────┴─────────────────┴──────────────┘
```

## Words

| word | meaning |
|---|---|
| glider | one glider database, named by a ref |
| ref | its name: `engineering/code`, `public/site` |
| store | a place gliders are kept |
| home | the store a glider is kept in. Exactly one |
| card | a glider's metadata: a JSON document in its store, a node in the catalog |
| catalog | this aerotow's graph of cards and stores |
| hangared | in its store, open nowhere |
| aloft | open on some aerotow, which holds its flight |
| flight | one period aloft, numbered per glider: 1, 2, 3, … |
| launch / land | open a glider here (restoring it if needed) / ship what is left and close it |
| instance | one running aerotow, with an id |

## Refs

```
ref     = segment *( "/" segment )            1 to 8 segments, at most 255 bytes
segment = [a-z0-9] *62( [a-z0-9._-] )         and never contains ".gldb"
```

Lower case only, so a ref means the same thing on a case-insensitive disk and
in a bucket. A segment cannot start with `_` or `.`: names that do
(`_flights`) are aerotow's own, which is what keeps `a` and `a/b` from
colliding in a store. `Aerotow.Ref.parse/1` is the only way a string from
outside (an API call, a card, a peer) becomes a path or a key (R1).

## The catalog

One glider file, `<dir>/catalog.gldb`, owned by this instance.

```
(:Store   {name, kind, url, cas, scanned_at})
(:Glider  {ref, namespace, name, description, tags, mode, hot,
           nodes, edges, bytes, schema, text,
           flight, generation, position, aloft, known,
           created_at, updated_at, described_at, …attrs})
(:Label {name})   (:EdgeType {name})   (:Tag {name})

(:Glider)-[:HOMED_IN]->(:Store)             exactly one
(:Glider)-[:ALSO_IN]->(:Store)              the same ref seen in a second store
(:Glider)-[:HAS_LABEL {count}]->(:Label)
(:Glider)-[:HAS_TYPE  {count}]->(:EdgeType)
(:Glider)-[:TAGGED]->(:Tag)
(:Glider)-[:LINKS_TO]->(:Glider)            declared links; the target may be a stub (known: false)
```

`attrs` are the embedding application's own flat properties (`visibility`,
`owner`, `org`); they sit on the node beside aerotow's so they can be
filtered on. Names aerotow uses are refused as attrs.

Indexes on `:Glider(ref)`, `:Store(name)`, `:Label(name)`, `:EdgeType(name)`,
`:Tag(name)`. The `context` extension is installed and indexes `ref`,
`description` and `text` (the labels, types and tags as words), which is what
`Aerotow.search/3` uses.

```cypher
-- which gliders hold code, and where are they kept
MATCH (g:Glider)-[:HAS_LABEL]->(:Label {name: "CodeEntity"}), (g)-[:HOMED_IN]->(s:Store)
RETURN g.ref, s.name, g.nodes ORDER BY g.nodes DESC

-- everything public in the assets bucket
MATCH (g:Glider)-[:HOMED_IN]->(:Store {name: "assets"}) WHERE g.visibility = "public" RETURN g.ref

-- what links to the glossary
MATCH (g:Glider)-[:LINKS_TO]->(:Glider {ref: "public/glossary"}) RETURN g.ref
```

**The store is the truth; the catalog is the map.** Every card lives beside
its glider in the store. The catalog is what this instance has read of them,
so it can be thrown away and rebuilt with `Aerotow.scan/2` (R2), and two
instances pointed at one bucket converge without talking to each other. What
the catalog adds is what only this instance knows: its stores, what is aloft
here.

It is kept current three ways: this instance's own writes (create, land,
describe), a scan of each store every `scan_interval`, and a lookup on a miss:
routing a ref the catalog has never seen reads `cards/<ref>.json` from each
store before answering "no such glider" (R3).

Glider's dialect has no `MERGE`, so an upsert is a match and then a create,
inside one transaction, in the one process that writes the catalog.

## Stores

| kind | url | what is there | who may open a glider |
|---|---|---|---|
| `file` | a directory, `kind: :file` | live databases, `<root>/<ref>.gldb` | whoever takes the file's lock |
| `dir` | a directory | replicas (glider's base + log layout) | whoever holds the flight |
| `s3` | `s3://bucket/prefix` | the same, in a bucket | whoever holds the flight |
| `peer` | `http(s)://host/path` | another aerotow | that aerotow; this one forwards |

A `file` store is for gliders that live on this machine and nowhere else: the
file is opened where it lies, and landing only closes it. `dir` and `s3`
stores hold replicas, which nothing opens in place: a launch restores one
into this instance's working directory, and what is written there is shipped
back. A `peer` store holds nothing aerotow can read as bytes; it answers
questions.

Credentials (S3 keys, peer tokens) are given with the store and kept in the
running instance only. The catalog records a store's name, kind and url with
any credentials stripped (R4).

### Layout of a dir or s3 store

```
aerotow.json                                    {"format": 1, "id": …, "created_at": …}
cards/<ref>.json                                the card
gliders/<ref>/_flights/<n>.json                 the record of flight n (the lease)
gliders/<ref>/_flights/<n>/<generation>/…       what flight n shipped: glider's own replica layout
        base/<lsn>/db, data/*.seg, base.json
        segments/<offset>-<unix>.seg
```

`<n>` is ten decimal digits, zero padded. Everything under one flight's
directory is written by that flight and by nothing else (R5): that is the
fence. The directory is exactly what `Glider.Replication.sync/3` and
`restore/3` take as a replica url, so glider's own code reads and writes it.

Listing all cards is one listing of `cards/`. Listing a glider's flights is
one listing of `gliders/<ref>/_flights/` with a delimiter, which returns the
records and not the thousands of segment objects beneath them.

### Layout of a file store

```
<ref>.gldb                 the database (glider adds <ref>.gldb-wal/, -data/, .lock beside it)
<ref>.card.json            the card
```

### Cards

```json
{
  "format": 1,
  "ref": "engineering/code",
  "description": "the code graph",
  "tags": ["code"],
  "attrs": {"visibility": "organization"},
  "links": ["public/glossary"],
  "mode": "auto",
  "hot": null,
  "nodes": 120000, "edges": 250000, "bytes": 268435456,
  "labels": [{"name": "CodeEntity", "count": 30000}],
  "types":  [{"name": "CALLS", "count": 80000}],
  "indexes": [{"name": ":CodeEntity(path)", "count": 30000}],
  "extensions": ["context"],
  "schema": "…the context extension's schema card, when it is installed…",
  "flight": 7, "generation": "96348bfb24205901…", "position": 1048665,
  "created_at": 1763400000, "updated_at": 1763400100, "described_at": 1763400100
}
```

Only the instance holding a glider's flight writes its card. Counts and
schema are read from the glider when it lands and after `describe/2`.
`flight`, `generation` and `position` say where the newest shipped state was
when the card was written; they are a hint for people, and a launch reads the
flight records instead of trusting them.

A card arriving from a store or a peer is input: refs are parsed, sizes are
bounded, unknown fields are ignored, and nothing in it becomes an atom (R6).

## Flights

Glider has one writer per database, and nothing in a bucket can enforce that.
Aerotow enforces it with flights.

A **flight** is one instance's turn with a glider. Its record,
`gliders/<ref>/_flights/<n>.json`, is the lease:

```json
{
  "format": 1, "ref": "engineering/code", "n": 7,
  "holder": "9c1e…", "node": "app@10.0.0.7", "url": "https://west.example.com/aerotow",
  "started_at": 1763400000000, "expires_at": 1763400030000,
  "from": {"flight": 6, "generation": "96348bfb…", "position": 1040112},
  "landed": false, "landed_at": null,
  "shipped": {"generation": "96348bfb…", "position": 1048665, "bases": 1}
}
```

Times are unix milliseconds on the holder's clock.

- **R7. A flight record is created exclusively.** Creating flight `n` either
  makes the record or fails because it exists: `O_EXCL` in a directory,
  `If-None-Match: *` in a bucket. Only its holder ever rewrites it.
- **R8. The current flight is the highest `n`.** It is *active* while
  `landed` is false and `now < expires_at + grace`.
- **R9. To take a glider up**, read the current flight. Active and somebody
  else's: it is aloft elsewhere, so forward to the holder or say so. Otherwise
  create `n + 1`. Losing that race means somebody else just took off: read
  again.
- **R10. The holder renews** `expires_at = now + ttl` every `ttl / 3`. If it
  reaches `expires_at - margin` without a renewal that succeeded, the flight
  is *lost*: it stops answering at once, ships nothing more, and gives the
  glider up.
- **R11. Every write and every shipping pass first checks** that the lease
  has not reached `expires_at - margin`, on the local clock. With
  `sync: :commit`, a write is acknowledged only if the lease is still inside
  that bound after its log has been shipped.
- **R12. A launch restores from the newest earlier flight that got a whole
  base into the store**, found by looking at the flight directories
  themselves, not by trusting a record or the card. A flight that shipped
  nothing is skipped through its `from`.
- **R13. Nothing is restored from a flight that is still active.**

Defaults: `ttl` 30 s, `margin` 5 s, `grace` 5 s. Two instances whose clocks
disagree by less than `margin + grace` never both believe they hold a flight.

Because each flight ships into its own directory, a holder that was frozen
and wakes up after its lease ran out (a paused VM, a long GC, a partition)
can only write into a directory nobody reads from any more. Its late writes
are lost; nothing it does can corrupt what the next flight shipped. That is
why there is one directory per flight instead of one per glider.

What this costs: a flight that writes uploads a whole base once, at its first
shipping pass, because glider starts a replica with a base. A flight that
only reads uploads nothing. Small gliders do not notice. A large glider that
is written often should stay aloft (`pin: true`) or live in a `file` store.
Shipping only the log when a flight continues from another is engine work,
listed under "Later".

### A flight's life

```
              launch                         idle, evicted, or asked
  hangared ────────────▶ launching ──▶ aloft ─────────────────────▶ landing ──▶ hangared
                             │           │  ▲                          │
                             │           │  └── final ship failed ─────┘
                             ▼           ▼
                           failed       lost   (lease ran out: stop, keep the copy aside)
```

- **launching**: take the flight (R9), restore the newest shipped state into
  `<dir>/flights/<store>/<ref>.gldb`, or into memory (or create an empty
  database for a new glider), open it. Callers wait. Where it goes is
  decided here ("Where the pages live").
- **aloft**: statements run. The handle is lent to the calling process for
  each statement (a checkout), so a long query runs in its caller and never
  delays a lease renewal. Writes mark the flight dirty; a dirty flight ships
  every `sync_interval` (1 s), or before a write is acknowledged with
  `sync: :commit`.
- **landing**: no new checkouts; wait for the ones out; ship what is left;
  read the glider's counts and schema and write its card; mark the record
  `landed` with what was shipped; close; delete the working copy. If the last
  ship fails and the lease still holds, the flight stays aloft and tries
  again.
- **lost**: refuse everything, close. A working copy with log that never
  shipped is moved to `<dir>/orphans/`, not deleted (R14); a memory flight
  writes a replica there before it closes.

A `file` store has no flights: launching opens the file where it is, and
glider's own lock file is the guard. Landing closes it.

### Carrying a copy into a new flight

A working copy left behind (a crash, a lost lease whose store came back) is
worth more than the store's copy: it has log that never shipped. If its
flight is still the newest one in the store, this instance takes the next
flight and starts it from that copy instead of restoring (R15). If a newer
flight exists, somebody else moved on and the copy stays in `orphans/`.

An instance's id is kept in `<dir>/instance.json`, and `catalog.gldb`'s lock
means one instance per `dir`. So a flight whose holder is this instance's own
id, with no process behind it, is known to be dead and is taken over at once
instead of after `ttl`. An instance on a disk that does not survive restarts
gets a new id each time; give it `id:` (a pod name) to keep that.

### Retention

Once a newer flight has a whole base in the store, older flights' directories
and records are deleted when they are older than `retention` (a day). Within
one flight, glider's own retention trims bases and log. Only the holder runs
either.

### How many are aloft

`max_aloft` (64) and `budget` (bytes of working copies and of memory flights;
unlimited by default)
bound what is open here. Past either, the least recently used flights that
nobody has checked out are landed. `idle` (5 minutes) lands a flight nobody
has used. `pin: true` keeps one up.

## Where a statement runs

```
1. aloft here                      → here
2. home is a peer store            → forward to the peer
3. home is a file store            → launch here (open in place)
4. home is a dir or s3 store
   current flight active, not ours → forward to its holder
   otherwise                       → launch here
```

Forwarding to a holder uses, in order: Erlang distribution when the record's
`node` is a connected node running an aerotow of the same name; HTTP when the
record has a `url` and this instance has a peer store with that url (and so a
token for it); otherwise `{:error, {:aloft_elsewhere, holder}}`. A node name
from a record is only ever compared with the names of connected nodes, never
turned into an atom (R16). A forwarded request carries a hop count and is
refused past three.

The catalog is consulted for the home; on a miss the stores are asked (R3).

## The interface

```elixir
children = [
  {Aerotow,
   name: MyApp.Aerotow,
   dir: "/var/lib/aerotow",
   stores: [
     {"disk",   "/var/lib/gliders", kind: :file},
     {"assets", "s3://graphs/gliders", endpoint: "http://minio.internal:9000",
                access_key_id: key, secret_access_key: secret},
     {"west",   "https://west.example.com/aerotow", token: token}
   ],
   default_store: "assets"}
]
```

`tow` below is that name.

| | |
|---|---|
| **stores** | |
| `add_store(tow, name, url, opts)` | add one while running; probes it |
| `remove_store(tow, name)` | forget it (its gliders leave the catalog) |
| `stores(tow)` | the stores, without credentials |
| `scan(tow, store \\ :all)` | read the cards in a store into the catalog |
| **gliders** | |
| `create(tow, ref, opts)` | a new, empty glider: `store:`, `description:`, `tags:`, `attrs:`, `links:`, `mode:`, `hot:` |
| `adopt(tow, ref, path, opts)` | bring an existing `.gldb` file in |
| `update(tow, ref, changes)` | description, tags, attrs, links, mode, hot |
| `describe(tow, ref)` | re-read counts and schema from the glider |
| `card(tow, ref)` | its card |
| `delete(tow, ref, purge: false)` | drop it from the catalog; `purge: true` deletes it from its store |
| **find** | |
| `find(tow, cypher, params)` | read-only Cypher over the catalog |
| `gliders(tow, opts)` | a page of cards: `store:`, `tag:`, `label:`, `type:`, `prefix:`, `limit:`, `after:` |
| `search(tow, text, opts)` | cards by full text, best first |
| `catalog(tow)` | the catalog's glider handle, for `Glider.Context` and the like. Read it; do not write it |
| **interact** | |
| `query(tow, ref, cypher, params, opts)` | a statement that reads |
| `run(tow, ref, cypher, params, opts)` | a statement that writes; `sync: :commit` ships before it returns |
| `write_batch(tow, ref, statements, opts)` | up to 1,000 writes, all or none |
| `context(tow, ref, opts)` | `Glider.Context.retrieve/2` on that glider |
| `schema(tow, ref)`, `stats(tow, ref)` | as `Glider.schema/1`, `Glider.stats/1` |
| `checkout(tow, ref, fun, opts)` | `fun.(db)` with the open handle, here; for transactions, `Glider.Query`, ash_glider |
| **flights** | |
| `launch(tow, ref, opts)` | open it now; `pin: true` keeps it aloft |
| `land(tow, ref)` | ship and close it |
| `sync(tow, ref)` | ship now |
| `aloft(tow)` | what is open here |
| `where(tow, ref)` | `:here`, `{:elsewhere, holder}`, `{:peer, store}`, `:hangared` |

Results are glider_ex's own: `{:ok, %Glider.Result{}}`, `{:ok, touched}`,
`{:error, reason}`. A forwarded statement returns the same terms.

`query/5` takes only statements that provably read: `MATCH … RETURN`,
`CALL` of a built-in algorithm with no `write:`, the `context` extension's
reading procedures, `STATS`, `SCHEMA`, `SHOW EXTENSIONS`, `HELP`, and
`EXPLAIN` of any of those. Anything else is refused with a message naming
`run/5` (R17). The check (`Aerotow.Statement`) follows glider's own lexer
and grammar, so a keyword inside a string, after `.` or after `:` is not a
statement, while a name in backticks is a keyword wherever glider would
read one; whatever it cannot place is a write. `find/3` applies the same
check to the catalog.

`run/5` and `write_batch/3` refuse `BEGIN`, `COMMIT` and `ROLLBACK`: sent
as text, they turn autocommit off for the whole handle, behind the backs of
every other caller. A transaction is `checkout/4` with
`Glider.transaction/2`. `checkout/4` runs here only: with the glider aloft
elsewhere it returns `{:error, {:aloft_elsewhere, holder}}`.

Statements are untrusted input. Before glider's `fix/bounded-depth` (#11)
a statement nested about 120 deep overflowed the stack and took the whole
VM down with it. Aerotow pins a glider with that fix: nesting deeper than
64 levels is an error, and flat chains (`AND`, `OR`, `+`, comma patterns)
are limited only by size. `Aerotow.Statement` counts depth as glider does.

## Peers

Another aerotow, typically inside another application, mounted as a plug:

```elixir
forward "/aerotow", Aerotow.Plug, tow: MyApp.Aerotow, authorize: &MyApp.Auth.aerotow/2
```

Everything is `POST <base>/v1/<op>` with a JSON body, plus `GET <base>/v1` for
`{aerotow, id, format}`.

| op | body | answer |
|---|---|---|
| `gliders` | `{after, limit, prefix}` | `{gliders: [card], next}` |
| `card` | `{ref}` | the card |
| `create` | `{ref, description, tags, attrs, links, store}` | the card |
| `update` | `{ref, changes}` | the card |
| `delete` | `{ref, purge}` | `{}` |
| `query` | `{ref, cypher, params, max_rows, max_bytes, graph}` | `{columns, rows, graph, message}` |
| `run` | `{ref, cypher, params, sync}` | `{touched, message}` |
| `batch` | `{ref, statements: [[cypher, params]]}` | `{touched}` |
| `context` | `{ref, …retrieve options}` | `{text, tokens, nodes, edges, refs}` |
| `schema`, `stats` | `{ref}` | as the local call |
| `find` | `{cypher, params}` | `{columns, rows}` over the peer's catalog |
| `search` | `{query, top}` | `[{ref, score, card}]` |

Nodes and relationships travel as glider's own typed objects,
`{"_e": "node", "id", "labels", "props"}` and `{"_e": "rel", "id", "type",
"from", "to", "props"}`, and come back as `%Glider.Node{}` and `%Glider.Rel{}`.
Errors are `{"error": message, "code": code}` with a matching status.

`authorize` is called with the connection and `%{op: op, ref: ref}` and
answers `:ok` or `{:error, status, message}`; `tokens: [...]` is the short
form, compared in constant time. A peer store is given `token:`. TLS is
whatever terminates in front of the plug.

A peer's gliders appear in this catalog through `scan`, homed in the peer
store, so `find` and `search` see them beside everything else. Statements for
them are forwarded; the peer does its own launching.

## Where the pages live: memory, disk, a hot set

Three ways for an aloft glider to hold its pages:

| mode | pages | log | what RAM holds |
|---|---|---|---|
| `memory` | in RAM | in RAM until shipped | the whole graph, at most `max_memory` |
| `disk` | a working file | on disk until shipped | a shared page cache, best effort |
| `disk` with `hot:` | a working file | on disk until shipped | the cache, plus a protected hot set that survives pressure and is warm at launch |

The replica in the store is the same in every case: a base and the log after
it. A glider flown in memory on one flight is flown from disk on the next if
its card says so then, and back; each launch restores the same replica into
whichever place it flies from, on the same lineage.

**Who decides.** Where the pages live is decided once per flight, as it
launches (`Aerotow.Flight.Copy.decide/4`), and holds until it lands: a
change made with `update/3` takes effect at the next launch. `mode` is the
first of these that is set: the instance's `mode:`, the store's `mode:`
option, the card's `mode` (`"auto"` unless somebody changed it). `hot` is
chosen the same way from the instance's `hot:`, the store's `hot:` and the
card's `hot`; `0` at any of them is "no hot set" and stops the search there.

- **`auto`** flies a glider in memory when its card says it is smaller than
  `memory_threshold` (64 MiB), and from disk otherwise. A new glider (no
  size yet) starts in memory. A glider `auto` put in memory whose replica
  turns out not to fit in `max_memory` is flown from disk instead.
- **A `file` store's glider** is always flown from disk: its file is
  opened where it lies. An adopted file's first flight, and a working copy
  carried from disk (R15), are flown from disk too; the next launch decides
  afresh.
- **`hot`** applies to flights from disk only. It is a hot set of that many
  bytes, at most half of the page cache (`cache_size:` on the instance, the
  most page cache one glider from disk may use; glider's default is the
  process's whole budget).

**Memory.** A memory flight is `Glider.open(max_memory: …, log: true)` when
it is created, and `Glider.Replication.restore(url, :memory, …)` from the
newest shipped state when it launches; it ships with
`Glider.Replication.sync(db, url, …)`, from the handle, with no spool and no
`db:` polling. Nothing of it is under `<dir>/flights/`. `max_memory` (an
instance option, 512 MiB by default) bounds each one: a replica that does not
fit is `{:error, {:launch, reason}}` with glider's reason ("… max_memory is
…"), the flight record it took is landed with nothing shipped, and nothing is
left behind; a write past it fails as glider fails it, rolled back. The
instance's `budget` counts a memory flight's bytes (`Glider.stats/1`'s
`memory_bytes`, measured by the caller after each statement and by each
shipping pass) beside working copies' bytes on disk.

A memory flight lost with log that never shipped has no file to move (R14).
Before it closes its handle it writes what it holds, a whole base, to a
directory replica, `<dir>/orphans/<store>/<ref>.<n>.replica/`, with the
flight's marker beside it. `orphans/1` lists it, and recovery carries it as
it carries a copy (R15): restored into the next flight, in memory or to disk
as the card says then, and removed once that flight is up.

**A hot set.** A flight from disk with `hot:` opens with `hot_size:`. Glider
keeps the list of hot pages beside the file and puts it in each base it
ships, and a restore lays it beside the copy, so a launch from a base is
warm. Since the list travels only with a base, a hot flight whose hot set
changed while it was up ships a new base, from a checkpoint taken then, as
the last pass of its landing. `info/1` reports the hot set's counters (`hot:
%{hot_capacity, hot_pages, hot_hits, promotions, demotions, prewarmed}`).

What it costs: a memory flight holds the whole graph, and what it wrote and
has not shipped dies with the VM (see "What can go wrong"). A hot flight
whose set moved uploads a whole base each time it lands.

## Processes

```
Aerotow.Supervisor (one per instance, named by `name:`)
├─ Registry              flights by ref
├─ Aerotow.Catalog       owns catalog.gldb; the only writer of it
├─ Task.Supervisor       shipping passes, scans
├─ DynamicSupervisor     one Aerotow.Flight per glider aloft here
└─ Aerotow.Server        stores and their credentials, the instance id, eviction, the scan timer
```

Reads of configuration (stores, the catalog handle) come from an ETS table
owned by the server, so a statement never waits behind a process that is
doing something else. A flight is `restart: :temporary`: one that dies is
relaunched by the next statement, through R15.

## What can go wrong

| what happens | what aerotow does |
|---|---|
| the holder is killed with unshipped log | after `ttl + grace` another instance launches from what was shipped; at most `sync_interval` of writes are gone (none with `sync: :commit`) |
| the VM holding a memory flight is killed | its unshipped writes are gone with it: there is no file to carry. That is the cost of memory; `sync: :commit` and a short `sync_interval` keep the window small |
| the holder restarts on the same disk | it finds its working copy and carries it into the next flight (R15): nothing is lost from disk; a memory flight left nothing to find |
| the holder freezes past its lease and wakes | its flight is lost (R10); what it ships lands in a directory nobody reads (R5) |
| two instances launch at once | one creates the record, the other fails and forwards (R7, R9) |
| the store is unreachable | renewals fail until `expires_at - margin`, then the flight is lost and its copy is kept in `orphans/` (R14; a memory flight writes a replica there); when the store is back the copy is carried into the next flight if nobody else took off |
| a card or record in the store is garbage | it is refused where it is read; a glider with no readable flight record does not launch |
| the catalog file is lost | `scan/2` rebuilds it from the stores (R2) |
| a bucket has no conditional writes | `add_store` reports `cas: false` and refuses to write there unless `single_writer: true` promises there is no second instance |
| a forward loops | refused at three hops |

## Telemetry

Spans, `[:aerotow, <event>, :start | :stop | :exception]`:
`:launch` (ref, store, flight, mode, from; bytes; `mode`, `"memory"` or
`"disk"`, is on its stop, being decided as it runs), `:land`, `:sync` (bytes,
bases, segments, lag), `:forward` (ref, op, via), `:scan` (store; seen,
added, updated, removed), `:statement` (ref, op, where). Events:
`[:aerotow, :lease, :renewed | :lost]`, `[:aerotow, :flight, :orphaned]`,
`[:aerotow, :evict]`. Glider's own `[:glider, …]` events come with every
statement as before.

## What this is not

- **Not a distributed database.** One writer per glider, at one place at a
  time. No consensus; a lease on a clock, fenced by directory.
- **Not a query planner across gliders.** A statement runs in one glider.
  Links between gliders are metadata.
- **Not read replicas.** One copy is aloft; everyone else forwards to it.
- **Not synchronous unless asked.** By default a write is acknowledged before
  it is shipped; `sync: :commit` waits.
- **Not an access-control layer.** `attrs` carry what the application needs
  to decide; the plug's `authorize` and the application's own calls enforce
  it.
- **Whole bases.** A written flight uploads one. Objects are single PUTs
  (glider's limit): a glider of many GB wants a `file` store today.
- **TLS to S3 through the `aws` CLI.** Glider's S3 client speaks plaintext.
  Aerotow's own requests (cards, records) use Req and do speak TLS.

## Later

- Flights that ship only log: restore leaves glider a spool to continue from,
  so a written flight does not start with a base.
- Read replicas: a second copy that follows the holder's log.
- Lazy launch: fetch the hot set first and the rest on demand.
- A mount prefix per store, so two stores can hold the same ref.
- Statements across gliders, following `LINKS_TO`.
- A standalone binary.

## Build plan

Slices, each with its own tests. A slice depends on those named after it.

| slice | what | needs |
|---|---|---|
| ref-card | `Aerotow.Ref`, `Aerotow.Card` (the struct, JSON in and out, reading counts and schema from an open glider) | |
| statement | `Aerotow.Statement`: reads and writes told apart | |
| catalog | `Aerotow.Catalog`: schema, upserts, find, page, search | ref-card, statement |
| store-dir | `Aerotow.Store` and its object layout; `Store.Dir`, `Store.File`; cards in and out | ref-card |
| store-s3 | `Store.S3` over Req (SigV4, conditional put, delimiter listing, probe); an S3 fake for tests | store-dir |
| lease | `Aerotow.Lease`: flight records, R7–R13, a clock that tests control | store-dir |
| flight | `Aerotow.Flight`, the registry and eviction: launch, checkout, ship, land, lose | lease, catalog |
| facade | `Aerotow`, `Aerotow.Server`, routing; create, adopt, scan, the whole table above, in one instance | flight, store-s3 |
| peer | `Aerotow.Wire`, `Aerotow.Plug`, `Aerotow.Store.Peer`; forwarding over HTTP and over distribution | facade |
| recovery | carrying a copy (R15), orphans (R14), retention, telemetry | facade |
| modes | memory flights and the hot set (glider #9, #10) | flight, engine |
