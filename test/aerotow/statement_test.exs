defmodule Aerotow.StatementTest do
  # Not async: one test counts atoms, and a module loading in another test at
  # the same moment would add some.
  use ExUnit.Case, async: false

  alias Aerotow.Statement

  doctest Aerotow.Statement

  # What every engine run starts from: two people, a machine, a DAG of three
  # edges, an index, and (unless a statement asks for a bare graph) the
  # context extension. Node ids are 1 (Ada), 2 (Bob), 3 (Engine).
  @seed [
    ~S|CREATE (a:Person {name: "Ada", age: 36})-[:KNOWS {since: 2019}]->(b:Person {name: "Bob", age: 41})|,
    ~S|CREATE (:Machine {name: "Engine"})|,
    ~S|MATCH (b:Person {name: "Bob"}), (m:Machine) CREATE (b)-[:BUILT]->(m)|,
    ~S|MATCH (a:Person {name: "Ada"}), (m:Machine) CREATE (a)-[:WROTE_ABOUT {year: 1843}]->(m)|,
    "INDEX ON :Person(name)"
  ]

  # The parameters random statements are run with: $p where a number goes,
  # $list after IN.
  @fuzz_params [p: 1, list: [1, 2]]

  # ------------------------------------------------------------------ corpus

  # Statements that read. Every one runs cleanly on the seed.
  @reads [
    # every kind of read
    "MATCH (n) RETURN n",
    "MATCH (n:Person {name: 'Ada'}) RETURN n.age",
    "MATCH (a:Person)-[:KNOWS]->(b) WHERE b.age > 30 RETURN b.name, count(*) AS n ORDER BY n DESC LIMIT 10",
    "MATCH (a)-[:KNOWS*1..3]->(b) RETURN DISTINCT b",
    "MATCH (a)<-[r:KNOWS]-(b) RETURN r, type(r)",
    "MATCH (a)<-->(b) RETURN a.name",
    "MATCH (a)--(b) RETURN count(a)",
    "MATCH (a:Person), (m:Machine) WHERE id(a) = 1 RETURN a, m",
    "MATCH (n) RETURN *",
    "MATCH (n)",
    "MATCH (n:Person) WHERE n.age >= 36",
    "MATCH (n) WHERE n.age IS NOT NULL AND NOT n.name STARTS WITH 'B' RETURN n.name ORDER BY n.name ASC SKIP 0 LIMIT 5",
    "MATCH (n) WHERE n.name CONTAINS 'd' OR n.name ENDS WITH 'b' OR n.age IS NULL RETURN n",
    "MATCH (n) WHERE n.age IN [36, 41] AND n.name <> 'Cy' AND n.name != 'Di' RETURN n",
    "MATCH (n) WHERE n.x IN [] RETURN n",
    "MATCH (n) RETURN labels(n)[0], [1, 2, 3][-1], n.name[0..2], n.name[..1], n.name[1..], [1][..]",
    "MATCH (n) RETURN n.age - 1, -n.age, 2 * 3 / 1, (n.age + 1) * 2",
    "MATCH (p:Person) RETURN context.card(p)",
    "MATCH (p:Person) RETURN context.tokens(p.name)",
    "STATS",
    "SCHEMA",
    "SHOW EXTENSIONS",
    "HELP",
    "CALL context.retrieve(query: \"ada\", budget: 200)",
    "CALL context.search(query: 'ada', top: 3)",
    "CALL context.paths(from: 1, to: 3)",
    "CALL context.schema()",
    "CALL context.help()",
    "EXPLAIN MATCH (n) RETURN n",
    "EXPLAIN MATCH (n:Person) WHERE n.name = 'Ada'",
    "EXPLAIN STATS",
    "EXPLAIN CALL pagerank()",
    # case and whitespace
    "match (n) return n",
    "MaTcH (n:Person) ReTuRn n.name",
    "explain match (n) return n",
    "stats",
    "Schema",
    "show Extensions",
    "help",
    "CALL PageRank(Top: 2)",
    "CALL Context . Search (query: 'ada')",
    "  \n\t MATCH (n) RETURN n  \n",
    " \t EXPLAIN MATCH (n) RETURN n",
    "MATCH\u{00A0}(n)\u{3000}RETURN\u{2028}n",
    "MATCH\t(n)\u{000B}RETURN\u{000C}n\u{0085}",
    "MATCH(n)RETURN(n)",
    "MATCH (n); RETURN n",
    ";;STATS;;",
    "EXPLAIN;MATCH (n) RETURN n",
    "CALL pagerank(top: 1,)",
    "CALL pagerank(top: - 1, damping: 0.85, dir: 'out')",
    "CALL pagerank(top: 3 - 1, iterations: -(-20))",
    "CALL pagerank(top: true - 1)",
    "CALL `context`.`search`(query: 'ada')",
    "MATCH (n) WHERE not n.age > 40 RETURN n",
    "MATCH (n) WHERE ! (n.age > 40) RETURN n",
    "MATCH (n) WHERE delete(n) RETURN n",
    "MATCH (n) RETURN n.name AS set ORDER BY set DESC SKIP 1 LIMIT 2",
    "MATCH (n) RETURN n.age = - - 36, n.age - -1",
    # keywords where the grammar reads a name
    "MATCH (n) WHERE n.name = \"CREATE\" RETURN n",
    "MATCH (n) WHERE n.name = 'SET n.x = 1' RETURN n",
    "MATCH (n) RETURN 'DETACH DELETE n', \"it's\", 'a \\'quoted\\' DELETE', \"a \\\"SET\\\"\"",
    "MATCH (n) RETURN n.set, n.delete, n.create, n.remove, n.detach, n.return",
    "MATCH (n) RETURN n.`SET`, n.`DELETE`",
    "MATCH (n:CREATE) RETURN n",
    "MATCH (n:`DELETE`) RETURN n",
    "MATCH (n)-[:SET]->(m) RETURN m",
    "MATCH (n)-[:DELETE|:REMOVE]->(m) RETURN m",
    "MATCH (set) RETURN set",
    "MATCH (delete)-[remove]->(create) RETURN delete, remove, create",
    "MATCH (as) WHERE as.name = 'Ada' RETURN as",
    "MATCH (n) WHERE set RETURN n",
    "MATCH (n) RETURN n.name AS delete, n.age AS `SET`",
    "MATCH (n) RETURN create(n), delete(n), set(n)",
    "MATCH (n) WHERE CREATE (m)",
    "MATCH (n) RETURN n // CREATE (m)",
    "MATCH (n) RETURN n //\rCREATE (m)",
    "MATCH (n) RETURN n -- c",
    "`MATCH` (n) `RETURN` n",
    "MATCH (n) RETURN `n`.name",
    "MATCH (n) RETURN n.pr\u{00E9}nom, n.\u{540D}\u{524D}, n.x\u{0663}",
    "MATCH (n) RETURN \"a\u{0000}b\""
  ]

  # Reads with parameters, run with them.
  @reads_with_params [
    {"MATCH (n) WHERE n.name = $delete RETURN n", [delete: "Ada"]},
    {"MATCH (n) WHERE n.name IN $set RETURN n.name", [set: ["Ada", "Bob"]]},
    {"MATCH (n) RETURN n LIMIT $create", [create: 1]},
    {"MATCH (n {name: $name}) RETURN n", [name: "Ada"]},
    {"MATCH (a)-[*1..$hops]->(b) RETURN b", [hops: 2]},
    {"CALL pagerank(top: $top)", [top: 2]}
  ]

  # Writes, and statements glider would not take. `changes: true` marks the
  # obvious writes, which must change the seeded graph; `seed: :bare` runs on
  # a graph without the context extension.
  @writes [
    {"CREATE (n:Person {name: 'Cy'})", changes: true},
    {"create (a)-[:R]->(b)", changes: true},
    {"`CREATE` (n:X)", changes: true},
    {"MATCH (n:Person) SET n.age = 1", changes: true},
    {"MATCH (n) SET n:Tagged, n.seen = true", changes: true},
    {"MATCH (n:Person) REMOVE n.age", changes: true},
    {"MATCH (n:Person) REMOVE n:Person", changes: true},
    {"MATCH (n:Machine) DELETE n", changes: true},
    {"MATCH (n) DETACH DELETE n", changes: true},
    {"MATCH (n) `DETACH` `DELETE` n", changes: true},
    {"MATCH (a:Person {name: 'Ada'}), (m:Machine) CREATE (a)-[:OWNS]->(m)", changes: true},
    {"MATCH (as) WHERE as DELETE as", changes: true},
    {"MATCH (n) WHERE n.name = 'Ada' SET n.set = 'RETURN'", changes: true},
    {"MATCH (set) SET set.delete = 1", changes: true},
    {"MATCH (n) WHERE n.name = 'nobody' SET n.x = 1", []},
    {"INDEX ON :Person(age)", changes: true},
    {"CREATE INDEX ON :Machine(name)", changes: true},
    {"DROP INDEX ON :Person(name)", changes: true},
    {"index :Person(age)", changes: true},
    {"CREATE EXTENSION context", seed: :bare, changes: true},
    {"CREATE EXTENSION IF NOT EXISTS context", seed: :bare, changes: true},
    {"DROP EXTENSION context", changes: true},
    {"DROP EXTENSION IF EXISTS context", changes: true},
    {"ALTER EXTENSION context UPDATE", []},
    {"CALL context.index()", changes: true},
    {"CALL Context.Index(labels: ['Person'])", changes: true},
    {"CALL `context.index`()", changes: true},
    {"CALL `CONTEXT.INDEX`()", changes: true},
    {"CALL context.unindex()", []},
    {"CALL context.search(query: 'ada', write: 'x')", []},
    {"CALL pagerank(write: null)", changes: true},
    {"CALL pagerank(WRITE: 'rank')", changes: true},
    {"CALL pagerank(`write`: 'rank')", changes: true},
    {"CALL \u{212A}core()", []},
    {"CALL \u{212A}core(write: 'k')", changes: true},
    {"CALL kcore(\u{212A}: 1)", []},
    {"CALL frobnicate()", []},
    {"CALL text.search(query: 'x')", []},
    {"CALL db.labels()", []},
    {"COMPACT", []},
    {"CLEAR", changes: true},
    {"BEGIN", []},
    {"COMMIT", []},
    {"ROLLBACK", []},
    {"EXPLAIN CREATE (n)", []},
    {"EXPLAIN MATCH (n) SET n.x = 1", []},
    {"EXPLAIN EXPLAIN MATCH (n) RETURN n", []},
    {"// a comment\nEXPLAIN MATCH (n) RETURN n", []},
    {"//abcde CREATE (n {x: '\nEXPLAIN MATCH (m) RETURN m //'})", []},
    {"`EXPLAIN` MATCH (n) RETURN n", []},
    {";EXPLAIN MATCH (n) RETURN n", []},
    {"EXPLAIN MATCH (n) WHERE n.name = $name RETURN n", params: [name: "Ada"]},
    {"EXPLAIN", []},
    {"", []},
    {"   ", []},
    {"// only a comment", []},
    {";", []},
    {"MATCH (n) RETURN n; CREATE (m)", []},
    {"MATCH (n) RETURN n CREATE (m)", []},
    {"MATCH (n) RETURN n //\nCREATE (m)", []},
    {"MATCH (n) WHERE n.name = 'Ada' SET n.x = 1 RETURN n", []},
    {"MATCH (n) RETURN n SET n.x = 1", []},
    {"STATS; STATS", []},
    {"MATCH (n) RETURN n.`name", []},
    {"MATCH (n) RETURN n.`x CREATE (m)", []},
    {"MATCH (n) RETURN \"unterminated", []},
    {"MATCH (n) RETURN 'a\\'", []},
    {"MATCH (n) RETURN 'it''s'", []},
    {"MATCH (n) RETURN `a``b`", []},
    {"MATCH (n) RETURN n /* comment */", []},
    {"MATCH (n) RETURN n # comment", []},
    {"MATCH (n) RETURN n\u{0000}", []},
    {"MATCH (n) RETURN 2EXPLAIN", []},
    {"MATCH (n) RETURN 1e", []},
    {"MATCH (n) RETURN n.a\u{2192}b", []},
    {"MATCH (n) RETURN \u{0663}", []},
    {"MATCH (n) RETURN (n.age)-1", []},
    {"MATCH (n) RETURN DISTINCT DISTINCT n", []},
    {"MATCH (n) RETURN n SKIP -1", []},
    {"MATCH (n) RETURN n LIMIT 99999999999999999999", []},
    {"MATCH (n)-[:A|B]->(m) RETURN m", []},
    {"MATCH (a)-[r*1..2]->(b) RETURN b", []},
    {"RETURN 1", []},
    {"MERGE (n:Person {name: 'Ada'})", []},
    {"WITH 1 AS x RETURN x", []},
    {"MATCH (n) RETURN n UNION MATCH (m) RETURN m", []},
    {"MATCH (p:Person) RETURN context.index(p)", []},
    {"MATCH (p:Person) RETURN `context.card`(p)", []},
    {"MATCH (n) RETURN frob.x(n)", []},
    {"CALL pagerank(top: n.x)", []},
    {"CALL pagerank(top: 1 + 1)", []},
    {"CALL pagerank(top: 'a' - 1)", []},
    {"CALL pagerank(top: [1, 2][0])", []},
    {"MATCH (n) RETURN n.name.first", []},
    {"MATCH (n) WHERE n.age = 1 = 1 RETURN n", []},
    {"CALL pagerank top: 1", []},
    {<<"MATCH (n) RETURN '", 0xFF, "'">>, []},
    {"DROP n", []},
    {"ALTER EXTENSION context", []},
    {"SHOW TABLES", []},
    {"HELP me", []}
  ]

  # Arguments the algorithms need to run on the seed.
  @algorithm_args %{
    "shortestpath" => "from: 1, to: 3",
    "path" => "from: 1, to: 3",
    "sssp" => "from: 1",
    "distances" => "from: 1",
    "bfs" => "from: 1",
    "dfs" => "from: 1",
    "neighbors" => "from: 1",
    "neighbours" => "from: 1",
    "subgraph" => "from: 1"
  }

  # The algorithms that store a result on every node they reach when given
  # write:. The others take the argument and ignore it.
  @storing ~w(pagerank betweenness closeness degree triangles clustering kcore
              components wcc scc communities labelprop sssp distances levels layers)

  # {expected class, statement, options}
  defp corpus do
    algorithms =
      for name <- Statement.algorithms() do
        args = Map.get(@algorithm_args, name)
        with_write = if args, do: args <> ", write: \"out\"", else: "write: \"out\""

        [
          {:read, "CALL #{name}(#{args})", []},
          {:write, "CALL #{name}(#{with_write})", changes: name in @storing}
        ]
      end

    Enum.map(@reads, &{:read, &1, []}) ++
      Enum.map(@reads_with_params, fn {statement, params} ->
        {:read, statement, params: params}
      end) ++
      Enum.map(@writes, fn {statement, opts} -> {:write, statement, opts} end) ++
      List.flatten(algorithms)
  end

  # ------------------------------------------------------------------ engine

  defp seed(kind) do
    {:ok, db} = Glider.open()
    for statement <- @seed, do: {:ok, _} = Glider.run(db, statement)
    if kind == :context, do: :ok = Glider.Context.install(db)
    db
  end

  # Everything a statement could have changed that can be read back: the
  # graph itself, its counts and schema, its extensions, and whether the
  # context extension's text index exists (only CALL context.search says).
  defp observe(db) do
    {:ok, jsonl} = Glider.export_jsonl(db)
    {:ok, stats} = Glider.stats(db)
    {:ok, schema} = Glider.schema(db)
    {:ok, extensions} = Glider.extensions(db)

    search =
      case Glider.query(db, ~S|CALL context.search(query: "ada")|) do
        {:ok, %Glider.Result{message: message}} -> message
        {:error, reason} -> reason
      end

    counts = Map.take(stats, ~w(nodes edges labels edge_types indexes))
    {jsonl, counts, schema, extensions, search}
  end

  # Runs a statement on a fresh seeded glider: what it looked like before,
  # glider's answer, and what it looked like after.
  defp run(statement, opts) do
    db = seed(Keyword.get(opts, :seed, :context))
    before = observe(db)
    result = Glider.query(db, statement, Keyword.get(opts, :params, []))
    after_run = observe(db)
    Glider.close(db)
    {before, result, after_run}
  end

  # What glider answers when a statement wrote, however little it touched.
  @wrote ~r/^(set \d+ values|removed \d+ values|deleted \d+ entities|created \d+ nodes|created index|dropped index|installed |dropped extension|updated |graph cleared|transaction open|committed|rolled back|compacted|indexed \d+ nodes|dropped the text index)/

  defp wrote?({:ok, %Glider.Result{message: message}}) when is_binary(message),
    do: message =~ @wrote

  defp wrote?(_result), do: false

  # What glider answers when its lexer or parser refuses a statement.
  @parse_error ~r/^(expected|unexpected|unrecognised statement|unterminated string|bad number|empty statement|missing parameter|variable-length patterns can't bind)/

  defp parse_error?({:error, reason}), do: reason =~ @parse_error
  defp parse_error?(_result), do: false

  defp refused?(statement) do
    case Statement.check_read(statement) do
      {:error, message} -> message =~ "glider would refuse"
      :ok -> false
    end
  end

  # -------------------------------------------------------------- classify

  describe "classify/1" do
    test "the corpus has over a hundred statements, of every kind" do
      corpus = corpus()
      assert length(corpus) >= 100
      assert Enum.count(corpus, &match?({:read, _, _}, &1)) >= 50
      assert Enum.count(corpus, &match?({:write, _, _}, &1)) >= 50
    end

    test "R17: reads are :read" do
      for {:read, statement, _} <- corpus() do
        assert Statement.classify(statement) == :read,
               "#{inspect(statement)} reads, but: #{inspect(Statement.check_read(statement))}"
      end
    end

    test "R17: writes, and anything glider would not take, are :write" do
      for {:write, statement, _} <- corpus() do
        assert Statement.classify(statement) == :write, "#{inspect(statement)} is not a read"
      end
    end

    test "R17: a keyword is only a keyword where glider's grammar reads one" do
      names = [
        "MATCH (n) RETURN 'CREATE (m)'",
        "MATCH (n) RETURN n.create, n.`DELETE`",
        "MATCH (n:SET) RETURN n",
        "MATCH (n)-[:DELETE]->(m) RETURN m",
        "MATCH (remove) RETURN remove",
        "MATCH (n) RETURN n AS detach",
        "MATCH (n) WHERE n.name = $delete RETURN n",
        "MATCH (n) RETURN n // SET n.x = 1",
        "MATCH (n) RETURN create(n)"
      ]

      for statement <- names, do: assert(Statement.classify(statement) == :read, statement)

      keywords = [
        "MATCH (n) `SET` n.x = 1",
        "MATCH (as) WHERE as DELETE as",
        "MATCH (n) WHERE n.x = 1 CREATE (m)",
        "MATCH (n) RETURN n //\nCREATE (m)",
        "`CREATE` (n)"
      ]

      for statement <- keywords, do: assert(Statement.classify(statement) == :write, statement)
    end

    test "R17: a CALL is a read only for an algorithm or a context procedure that reads, without write:" do
      assert Statement.classify("CALL degree(dir: 'in', top: 1)") == :read
      assert Statement.classify("CALL degree(dir: 'in', write: 'deg')") == :write
      assert Statement.classify("CALL degree(write: null)") == :write
      assert Statement.classify("CALL degree(Write: 'deg')") == :write
      assert Statement.classify("CALL nonesuch()") == :write
      assert Statement.classify("CALL context.search(query: 'x')") == :read
      assert Statement.classify("CALL context.index()") == :write
      assert Statement.classify("CALL context.unindex()") == :write
      assert Statement.classify("CALL context.nonesuch()") == :write
      assert Statement.classify("CALL other.search(query: 'x')") == :write
      assert Statement.classify("CALL `context.search`(query: 'x')") == :write
    end

    test "R17: EXPLAIN reads as what it explains, and only when glider parses what follows it" do
      assert Statement.classify("EXPLAIN MATCH (n) RETURN n") == :read
      assert Statement.classify("EXPLAIN CREATE (n)") == :write
      assert Statement.classify("EXPLAIN EXPLAIN MATCH (n) RETURN n") == :write
      assert Statement.classify("// first\nEXPLAIN MATCH (n) RETURN n") == :write
      assert Statement.classify("EXPLAIN MATCH (n) WHERE n.x = $x RETURN n") == :write
    end

    test "read?/1 agrees with classify/1" do
      for {_, statement, _} <- corpus() do
        assert Statement.read?(statement) == (Statement.classify(statement) == :read)
      end
    end

    test "something that is not a string is a write" do
      for term <- [nil, 1, :match, [~c"MATCH (n) RETURN n"], %{}, {"MATCH (n) RETURN n"}] do
        assert Statement.classify(term) == :write
        assert {:error, _} = Statement.check_read(term)
      end
    end
  end

  describe "check_read/1" do
    test "R17: it says what kind of statement it saw, and that writes go through Aerotow.run/5" do
      assert Statement.check_read("MATCH (n) RETURN n") == :ok
      assert Statement.check_read("CALL context.retrieve(query: 'ada')") == :ok

      for {statement, kind} <- [
            {"CREATE (n)", "CREATE"},
            {"MATCH (n) SET n.x = 1", "MATCH ... SET"},
            {"MATCH (n) DETACH DELETE n", "MATCH ... DETACH DELETE"},
            {"CALL pagerank(write: 'rank')", "CALL pagerank with a write: argument"},
            {"CALL context.index()", "CALL context.index"},
            {"CALL frob()", "an algorithm aerotow does not know"},
            {"CLEAR", "CLEAR"},
            {"BEGIN", "BEGIN"},
            {"EXPLAIN CREATE (n)", "EXPLAIN of CREATE"},
            {"MATCH (n) RETURN 'x", "glider would refuse (unterminated string)"},
            {"MATCH (n) RETURN n CREATE (m)", "after the end of the statement"},
            {"", "an empty statement"},
            {<<0xFF>>, "not UTF-8"}
          ] do
        assert {:error, message} = Statement.check_read(statement)
        assert message =~ kind
        assert message =~ "Aerotow.run/5"
      end
    end
  end

  # ------------------------------------------------------------ the engine

  describe "R17: it agrees with glider" do
    test "every statement classified :read leaves a seeded glider as it was" do
      reads =
        for {_, statement, opts} <- corpus(), Statement.read?(statement), do: {statement, opts}

      assert length(reads) >= 100

      for {statement, opts} <- reads do
        {before, result, after_run} = run(statement, opts)
        assert {:ok, _} = result, "#{inspect(statement)} is a read glider should run"

        assert after_run == before,
               "#{inspect(statement)} was classified :read and changed the graph"

        refute wrote?(result),
               "#{inspect(statement)} was classified :read and glider answered #{inspect(result)}"
      end
    end

    test "the writes glider accepts are real: the obvious ones change the graph" do
      runs =
        for {_, statement, opts} <- corpus(), not Statement.read?(statement) do
          {statement, opts, run(statement, opts)}
        end

      for {statement, opts, {before, result, after_run}} <- runs, opts[:changes] do
        assert {:ok, _} = result, "#{inspect(statement)} should run: #{inspect(result)}"
        assert after_run != before, "#{inspect(statement)} should have changed the graph"
      end

      changed = Enum.count(runs, fn {_, _, {before, _, after_run}} -> after_run != before end)
      accepted = Enum.count(runs, &match?({_, _, {_, {:ok, _}, _}}, &1))
      assert changed >= 40
      assert accepted >= 60
    end

    test "a statement this module says glider would refuse, glider refuses" do
      refused = for {_, statement, opts} <- corpus(), refused?(statement), do: {statement, opts}
      assert length(refused) >= 25

      for {statement, opts} <- refused do
        {_, result, _} = run(statement, opts)
        assert {:error, _} = result, "glider ran #{inspect(statement)}: #{inspect(result)}"
      end
    end

    test "statements made at random from glider's words: what is classified :read reads, and what this module says glider refuses, glider refuses" do
      :rand.seed(:exsss, {7, 8, 9})

      seen =
        Enum.reduce(1..1500, %{read: 0, refused: 0}, fn _, seen ->
          statement = random_statement()

          cond do
            Statement.read?(statement) ->
              {before, result, after_run} = run(statement, params: @fuzz_params)
              assert after_run == before, "#{inspect(statement)} is :read and changed the graph"

              refute wrote?(result),
                     "#{inspect(statement)} is :read and glider answered #{inspect(result)}"

              # A parameter's value decides whether some places parse (`IN $p`
              # wants a list, `LIMIT $p` an integer), so only a statement
              # without one says whether the two parsers agree.
              if not String.contains?(statement, "$") do
                refute parse_error?(result),
                       "this module parses #{inspect(statement)}, and glider refuses it: #{inspect(result)}"
              end

              %{seen | read: seen.read + 1}

            refused?(statement) ->
              {_, result, _} = run(statement, params: @fuzz_params)

              assert {:error, _} = result,
                     "this module says glider refuses #{inspect(statement)}, and glider ran it: #{inspect(result)}"

              %{seen | refused: seen.refused + 1}

            true ->
              seen
          end
        end)

      assert seen.read >= 200
      assert seen.refused >= 200
    end
  end

  # -------------------------------------------------------- not rotting

  describe "it does not rot silently" do
    test "every algorithm glider's HELP lists is one this module knows" do
      {:ok, %Glider.Result{message: help}} = with_db(&Glider.query(&1, "HELP"))
      names = help_algorithms(help)

      assert length(names) >= 20,
             "could not read the algorithms from glider's HELP; has its layout changed?\n#{help}"

      unknown = names -- Statement.algorithms()

      assert unknown == [],
             "glider has algorithms Aerotow.Statement does not know: #{Enum.join(unknown, ", ")}. " <>
               "Read what each does in deps/glider/src/query.rs and add it to @algorithms if it only writes when given write:."
    end

    test "every name glider's algorithm dispatch takes, aliases included, is one this module knows" do
      source = File.read!(Path.join(Mix.Project.deps_paths()[:glider], "src/query.rs"))

      names =
        case String.split(source, "\nfn run_algorithm(", parts: 2) do
          [_, body] ->
            [body | _] = String.split(body, "\nfn ", parts: 2)

            for [arm] <- Regex.scan(~r/^\s*"[a-z_]+"(?:\s*\|\s*"[a-z_]+")*(?=\s*=>)/m, body),
                [name] <- Regex.scan(~r/[a-z_]+/, arm),
                do: name

          _ ->
            []
        end

      assert length(names) >= 20,
             "could not find run_algorithm's dispatch in glider's src/query.rs; has it moved?"

      unknown = names -- Statement.algorithms()

      assert unknown == [],
             "glider's run_algorithm takes names Aerotow.Statement does not know: #{Enum.join(unknown, ", ")}"
    end

    test "every algorithm this module knows is one glider runs" do
      with_db(fn db ->
        for name <- Statement.algorithms() do
          case Glider.query(db, "CALL #{name}()") do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              refute reason =~ "unknown algorithm",
                     "Aerotow.Statement knows #{name}, and glider does not: #{reason}"
          end
        end
      end)
    end

    test "every procedure and function of glider's context extension is one this module knows" do
      {:ok, %Glider.Result{rows: rows}} = with_db(&Glider.query(&1, "CALL context.help()"))
      procedures = for ["procedure", signature, _] <- rows, do: member(signature)
      functions = for ["function", signature, _] <- rows, do: member(signature)
      known = Statement.context_members()

      assert length(procedures) >= 4
      assert procedures -- (known.reads ++ known.writes) == []
      assert functions -- known.functions == []
      # help is answered by glider for every extension, outside the list.
      assert (known.reads -- ["help"]) -- procedures == []
      assert known.writes -- procedures == []
      assert known.functions -- functions == []
    end
  end

  # --------------------------------------------------------------- limits

  describe "limits" do
    test "a statement nested more than 32 levels deep is a write, and the deepest read glider runs" do
      nested = fn n -> "MATCH (n) WHERE " <> parens(n, "true") <> " RETURN n" end

      lists = fn n ->
        "MATCH (n) RETURN " <> String.duplicate("[", n) <> "1" <> String.duplicate("]", n)
      end

      minus = fn n -> "MATCH (n) RETURN " <> String.duplicate("- ", n) <> "1" end
      negated = fn n -> "MATCH (n) WHERE " <> String.duplicate("NOT ", n) <> "true RETURN n" end

      calls = fn n ->
        "MATCH (n) RETURN " <> String.duplicate("abs(", n) <> "1" <> String.duplicate(")", n)
      end

      for shape <- [nested, lists, minus, negated, calls] do
        assert Statement.classify(shape.(32)) == :read
        assert Statement.classify(shape.(33)) == :write
        assert {:error, message} = Statement.check_read(shape.(33))
        assert message =~ "nested more than 32 levels"
        assert {_, {:ok, _}, _} = run(shape.(32), [])
      end
    end

    test "an expression more than 128 levels deep is a write, and the deepest read glider runs" do
      chain = fn op, n ->
        "MATCH (n) WHERE " <> Enum.map_join(1..n, " #{op} ", fn _ -> "n.age" end) <> " RETURN n"
      end

      subscripts = fn n -> "MATCH (n) RETURN n.name" <> String.duplicate("[0]", n - 1) end

      for shape <- [
            &chain.("+", &1),
            &chain.("AND", &1),
            &chain.("OR", &1),
            &chain.("-", &1),
            subscripts
          ] do
        assert Statement.classify(shape.(128)) == :read
        assert Statement.classify(shape.(129)) == :write
        assert {:error, message} = Statement.check_read(shape.(129))
        assert message =~ "more than 128 levels deep"
        assert {_, {:ok, _}, _} = run(shape.(128), [])
      end
    end

    test "a statement longer than glider_ex takes is a write" do
      statement = "MATCH (n) RETURN n" <> String.duplicate(" ", 1_048_576)
      assert Statement.classify(statement) == :write
      assert {:error, message} = Statement.check_read(statement)
      assert message =~ "longer than 1048576 bytes"
      assert Statement.classify(binary_part(statement, 0, 1_048_576)) == :read
    end
  end

  # ------------------------------------------------------ arbitrary input

  describe "arbitrary input" do
    test "random bytes never raise, and nothing that is not UTF-8 reads" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..5000 do
        bytes = :rand.bytes(:rand.uniform(80) - 1)
        class = Statement.classify(bytes)
        assert class in [:read, :write]
        if not String.valid?(bytes), do: assert(class == :write)

        assert Statement.check_read(bytes) == :ok or
                 match?({:error, _}, Statement.check_read(bytes))
      end
    end

    test "random strings of glider's words never raise" do
      :rand.seed(:exsss, {4, 5, 6})

      for _ <- 1..5000 do
        statement = soup()
        assert Statement.classify(statement) in [:read, :write]
      end
    end

    test "null bytes, unterminated strings and names, invalid UTF-8 are writes" do
      for statement <- [
            "MATCH (n) RETURN n\u{0000}",
            "\u{0000}",
            "MATCH (n) RETURN 'abc",
            "MATCH (n) RETURN \"abc\\\"",
            "MATCH (n) RETURN `abc",
            <<"MATCH (n) RETURN n", 0xC3>>,
            <<0xFF, 0xFE>>,
            <<"MATCH (n) RETURN '", 0xED, 0xA0, 0x80, "'">>
          ] do
        assert Statement.classify(statement) == :write
      end
    end

    test "a megabyte of anything is classified quickly, with work in proportion to its length" do
      for {name, make, class} <- shapes() do
        large = make.(1_048_576)
        small = make.(131_072)
        assert byte_size(large) <= 1_048_576

        {time, large_class} = :timer.tc(fn -> Statement.classify(large) end)
        assert large_class == class, "#{name}: expected #{class}"
        assert time < 3_000_000, "#{name}: a megabyte took #{div(time, 1000)} ms"

        # Reductions count the calls made, so they measure the work itself;
        # the clock also measures garbage collection, which a larger heap
        # makes dearer per byte. Linear work is about 8 times as much here,
        # quadratic 64.
        large_work = reductions(fn -> Statement.classify(large) end)
        small_work = reductions(fn -> Statement.classify(small) end)

        assert large_work <= 12 * small_work + 10_000,
               "#{name}: 8 times the input took #{Float.round(large_work / max(small_work, 1), 1)} times the work"
      end
    end

    test "classifying makes no atoms" do
      :rand.seed(:exsss, {10, 11, 12})

      inputs =
        Enum.map(corpus(), fn {_, statement, _} -> statement end) ++
          Enum.map(shapes(), fn {_, make, _} -> make.(65_536) end) ++
          for(_ <- 1..2000, do: soup()) ++
          for(
            _ <- 1..500,
            do: "MATCH (n) RETURN n.zz_not_an_atom_#{System.unique_integer([:positive])}"
          )

      Enum.each(inputs, &Statement.check_read/1)
      before = :erlang.system_info(:atom_count)
      Enum.each(inputs, &Statement.check_read/1)
      Enum.each(inputs, &Statement.classify/1)
      assert :erlang.system_info(:atom_count) == before
    end
  end

  # -------------------------------------------------------------- helpers

  defp with_db(fun) do
    db = seed(:context)

    try do
      fun.(db)
    after
      Glider.close(db)
    end
  end

  # The names in HELP's "algorithms (CALL name(arg: value, ...))" section,
  # each written `name(args)`.
  defp help_algorithms(help) do
    case String.split(help, "algorithms (CALL name(arg: value, ...))", parts: 2) do
      [_, rest] ->
        [section | _] = String.split(rest, "\n\n", parts: 2)
        for [_, name] <- Regex.scan(~r/([a-z]+)\(/, section), do: name

      _ ->
        []
    end
  end

  # "context.retrieve(query, seeds, ...)" -> "retrieve"
  defp member(signature) do
    [_, rest] = String.split(signature, ".", parts: 2)
    rest |> String.split("(", parts: 2) |> hd()
  end

  defp parens(n, inner), do: String.duplicate("(", n) <> inner <> String.duplicate(")", n)

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_run} = Process.info(self(), :reductions)
    after_run - before
  end

  # Inputs of a given length that make a careless lexer or parser slow: one
  # token over and over, one token that never ends, or a read that is long
  # and valid. {name, length -> input, the class it must get}.
  defp shapes do
    [
      {"(", &String.duplicate("(", &1), :write},
      {"a megabyte read", &read_of(&1, "n, "), :read},
      {"EXPLAIN of a megabyte read", &("EXPLAIN " <> read_of(&1 - 8, "n, ")), :read},
      {"a long list", &list_of(&1), :read},
      {"names", &String.duplicate("a ", div(&1, 2)), :write},
      {"names outside ASCII", &read_of(&1, "\u{00E9}, "), :read},
      {"numbers", &String.duplicate("1 ", div(&1, 2)), :write},
      {"parameters", &String.duplicate("$a ", div(&1, 3)), :write},
      {"an unterminated string", &("'" <> String.duplicate("a", &1 - 1)), :write},
      {"escapes", &("\"" <> String.duplicate("\\\"", div(&1 - 1, 2))), :write},
      {"an unterminated name", &("`" <> String.duplicate("a", &1 - 1)), :write},
      {"a comment", &("// " <> String.duplicate("x", &1 - 3)), :write},
      {"whitespace", &("MATCH (n) RETURN n" <> String.duplicate(" ", &1 - 18)), :read},
      {"Unicode whitespace",
       &("MATCH (n) RETURN n" <> String.duplicate("\u{3000}", div(&1 - 18, 3))), :read},
      {"a chain of +",
       &("MATCH (n) WHERE " <> String.duplicate("1 + ", div(&1 - 30, 4)) <> "1 RETURN n"),
       :write},
      {"NOT",
       &("MATCH (n) WHERE " <> String.duplicate("NOT ", div(&1 - 30, 4)) <> "true RETURN n"),
       :write},
      {"unary minus", &("MATCH (n) RETURN " <> String.duplicate("- ", div(&1 - 20, 2)) <> "1"),
       :write},
      {"random bytes", &:rand.bytes/1, :write}
    ]
  end

  defp read_of(size, item) do
    count = div(size - 18, byte_size(item))
    "MATCH (n) RETURN " <> String.duplicate(item, count) <> "n"
  end

  defp list_of(size) do
    count = div(size - 40, 3)
    "MATCH (n) WHERE n.age IN [" <> String.duplicate("1, ", count) <> "1] RETURN n"
  end

  # ------------------------------------------------- random statements

  @words ~w(MATCH RETURN SET REMOVE DELETE DETACH CREATE WHERE AND OR NOT AS ORDER BY
            SKIP LIMIT DISTINCT CALL EXPLAIN IS NULL IN CONTAINS STARTS ENDS WITH INDEX
            ON DROP EXTENSION SHOW EXTENSIONS STATS SCHEMA HELP COMPACT CLEAR BEGIN
            COMMIT ROLLBACK true false null)
  @names ~w(n m a set delete create remove return as where detach x)
  @labels ~w(Person Machine CREATE SET DELETE RETURN)
  @symbols ~w"( ) ( ) [ ] { } : , . = < > - -> <- * + / | .. <> !="
  @literals ["1", "2.5", "-3", "'Ada'", "\"SET n.x = 1\"", "$p", "[1, 2]", "true", "null"]
  @gaps [" ", " ", " ", " ", "\n", "\t", " // DELETE n\n", " ; ", "\u{00A0}"]

  defp random_statement do
    statement =
      case :rand.uniform(8) do
        1 ->
          soup()

        2 ->
          call_statement()

        3 ->
          pick([
            spell("STATS"),
            spell("SCHEMA"),
            spell("HELP"),
            spell("SHOW") <> gap() <> spell("EXTENSIONS"),
            spell("CLEAR"),
            spell("BEGIN")
          ])

        _ ->
          match_statement()
      end

    if :rand.uniform(8) == 1, do: spell("EXPLAIN") <> gap() <> statement, else: statement
  end

  defp soup do
    vocabulary = @words ++ @names ++ @labels ++ @symbols ++ @literals
    Enum.map_join(1..:rand.uniform(12), fn _ -> spell(pick(vocabulary)) <> gap() end)
  end

  defp match_statement do
    where = maybe(gap() <> spell("WHERE") <> gap() <> expression(2))

    tail =
      case :rand.uniform(9) do
        1 -> spell("SET") <> gap() <> set_item()
        2 -> spell("REMOVE") <> gap() <> pick(@names) <> "." <> pick(@names)
        3 -> spell("DETACH") <> gap() <> spell("DELETE") <> gap() <> pick(@names)
        4 -> spell("DELETE") <> gap() <> pick(@names)
        5 -> spell("CREATE") <> gap() <> pattern()
        6 -> ""
        _ -> spell("RETURN") <> gap() <> return_items()
      end

    spell("MATCH") <> gap() <> pattern() <> where <> gap() <> tail
  end

  defp pattern do
    node = fn ->
      "(" <>
        maybe(pick(@names)) <>
        maybe(":" <> spell(pick(@labels))) <> maybe(" {name: " <> pick(@literals) <> "}") <> ")"
    end

    link = fn ->
      pick([
        "-->",
        "<--",
        "--",
        "-[:" <> pick(@labels) <> "]->",
        "-[" <> pick(@names) <> "]-",
        "-[*1..2]->",
        "<-[:KNOWS|:BUILT]-"
      ])
    end

    Enum.reduce(List.duplicate(nil, :rand.uniform(3) - 1), node.(), fn _, acc ->
      acc <> link.() <> node.()
    end)
  end

  defp expression(0), do: operand()

  defp expression(depth) do
    case :rand.uniform(9) do
      1 ->
        expression(depth - 1) <>
          gap() <> spell(pick(~w(AND OR))) <> gap() <> expression(depth - 1)

      2 ->
        spell("NOT") <> gap() <> expression(depth - 1)

      3 ->
        expression(depth - 1) <>
          gap() <> pick(~w(= <> < > <= >= !=)) <> gap() <> expression(depth - 1)

      4 ->
        expression(depth - 1) <>
          gap() <> spell("IS") <> gap() <> maybe(spell("NOT") <> gap()) <> spell("NULL")

      5 ->
        expression(depth - 1) <> gap() <> spell("IN") <> gap() <> pick(["[1, 2]", "$list", "[]"])

      6 ->
        "(" <> expression(depth - 1) <> ")"

      7 ->
        pick(@names) <> "(" <> expression(depth - 1) <> ")"

      8 ->
        expression(depth - 1) <> gap() <> spell(pick(~w(CONTAINS + - *))) <> gap() <> operand()

      _ ->
        operand()
    end
  end

  defp operand do
    pick([
      pick(@names),
      pick(@names) <> "." <> spell(pick(@names ++ @words)),
      pick(@literals),
      "context.card(" <> pick(@names) <> ")",
      spell(pick(@words))
    ])
  end

  defp return_items do
    items =
      Enum.map_join(1..:rand.uniform(3), ", ", fn _ ->
        expression(1) <> maybe(gap() <> spell("AS") <> gap() <> spell(pick(@names ++ @words)))
      end)

    pick(["*", items]) <>
      maybe(gap() <> spell("ORDER") <> gap() <> spell("BY") <> gap() <> operand()) <>
      maybe(gap() <> spell(pick(~w(SKIP LIMIT))) <> gap() <> pick(["1", "$p", "-1"]))
  end

  defp set_item do
    pick([
      pick(@names) <> "." <> pick(@names) <> " = " <> expression(1),
      pick(@names) <> ":" <> pick(@labels)
    ])
  end

  defp call_statement do
    name =
      pick(
        Statement.algorithms() ++
          ~w(context.search context.index context.retrieve context.schema frob)
      )

    args =
      Enum.map_join(List.duplicate(nil, :rand.uniform(4) - 1), ", ", fn _ ->
        spell(pick(~w(top write from to dir query))) <> ": " <> pick(@literals)
      end)

    spell("CALL") <> gap() <> name <> pick(["(" <> args <> ")", "()", ""])
  end

  defp pick(list), do: Enum.random(list)
  defp gap, do: pick(@gaps)
  defp maybe(text), do: if(:rand.uniform(2) == 1, do: text, else: "")

  # A word as somebody might type it: as it is, lower case, mixed case, or
  # in backticks.
  defp spell(word) do
    case :rand.uniform(6) do
      1 -> String.downcase(word)
      2 -> "`" <> word <> "`"
      3 -> word |> String.graphemes() |> Enum.map_join(&mixed/1)
      _ -> word
    end
  end

  defp mixed(char),
    do: if(:rand.uniform(2) == 1, do: String.upcase(char), else: String.downcase(char))
end
