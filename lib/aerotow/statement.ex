defmodule Aerotow.Statement do
  @max_bytes 1_048_576
  @max_nesting 32
  @max_height 128

  @moduledoc """
  Tells a statement that reads from one that writes.

  `Aerotow.query/5` and `Aerotow.find/3` take only statements that provably
  read; anything else is refused with a message naming `Aerotow.run/5`. This
  module is that check. It reads the text and runs nothing.

  A statement reads when glider would parse it as one of:

    * `MATCH … RETURN …`, or a `MATCH` with no tail (a count)
    * `CALL` of a built-in algorithm (`algorithms/0`) with no `write:`
      argument
    * `CALL context.retrieve`, `context.search`, `context.paths`,
      `context.schema` or `context.help`
    * `STATS`, `SCHEMA`, `SHOW EXTENSIONS`, `HELP`
    * `EXPLAIN` of one of those

  Everything else is a write: every other kind of statement; a `CALL` with a
  `write:` argument, whatever its value (`write: null` stores a property
  called `null`); an algorithm, an extension procedure or an extension
  function this module does not know; and anything glider would refuse,
  which includes the empty statement and two statements in one. When in
  doubt, it is a write: a read that is refused is an inconvenience, and a
  write that passes as a read is the failure that matters.

  ## Glider's grammar, not Cypher's

  The check follows glider's own lexer and parser (`src/query.rs` at the
  version aerotow pins: `lex_with`, `parse_stmt` and what it calls) token
  for token, so it agrees with the engine rather than with Cypher in general:

    * A keyword is a keyword only where the grammar reads one. In a string,
      after `.` or `:`, as a variable, an alias, a function name or a
      parameter it is a name: `MATCH (set) RETURN set.delete AS create`
      reads. Where a keyword is expected, a name in backticks is one: glider
      runs ``MATCH (n) `DETACH` `DELETE` n``.
    * The tail of a `MATCH` is where glider finds it, after the patterns and
      the `WHERE` expression: `MATCH (as) WHERE as DELETE as` deletes, and
      `MATCH (n) WHERE CREATE (m)` counts (`CREATE (m)` is a function call).
    * Strings are in `"` or `'`, with backslash escapes and no doubled
      quotes. The only comment is `//` to the end of the line: `--` is two
      minus signs and `/* */` is not a comment. Whitespace is Unicode's.
      `;` is skipped wherever it is, so `MATCH (n); RETURN n` is one
      statement.

  Some spellings glider accepts but reads from somewhere unexpected. They
  are writes here:

    * a backtick name with no closing backtick, which glider takes to the end
      of the statement
    * `EXPLAIN` after a comment, a `;` or a backtick: glider parses the
      statement again from 7 bytes past its first non-blank character
    * a quoted name with a dot in it where glider looks for a procedure or a
      function: ``CALL `context.index`()`` runs `context.index`
    * an algorithm, a procedure or an argument named with characters outside
      ASCII: glider lowercases those with Unicode's rules, so `kcore` spelled
      with a Kelvin sign (U+212A) for its `k` runs `kcore`

  ## Limits

  Glider parses and evaluates statements recursively, and a statement deep
  enough overflows the native stack and takes the whole VM down: about 120
  levels of parentheses will do it, and so will a chain of about 800
  operators. So a statement nested more than #{@max_nesting} levels deep, or
  with an expression more than #{@max_height} levels deep, is not taken as a
  read. Nor is one longer than #{@max_bytes} bytes (more than glider_ex
  accepts) or one that is not UTF-8.

  Classifying is linear in the length of the statement and makes no atoms.
  """

  # The built-in algorithms, as glider's run_algorithm dispatches them,
  # aliases included. Each stores its results only when given `write:`.
  # Anything not named here is a write.
  @algorithms ~w(pagerank betweenness closeness degree triangles clustering kcore
                 components wcc scc communities labelprop shortestpath path sssp
                 distances bfs dfs neighbors neighbours subgraph toposort topo
                 levels layers reduce reduction cycle cycles mst)

  # The context extension, the only one glider builds in.
  @context_reads ~w(retrieve search paths schema help)
  @context_writes ~w(index unindex)
  @context_functions ~w(card tokens)

  # A name longer than this is never a keyword or a name this module knows,
  # so it is not lowercased.
  @max_key 16

  # The tokens that can go on with an expression after an operand: a
  # subscript, an operator, a call or a property.
  @goes_on [:"[", :*, :/, :+, :-, :<>, :!=, :<=, :>=, :=, :<, :>, :"(", :.] ++
             ~w(is in contains starts ends and or)

  @doc """
  Whether `statement` reads or writes. It never raises, whatever it is given:
  anything that does not provably read is `:write`.

      iex> Aerotow.Statement.classify("MATCH (n:Person) WHERE n.name = 'SET' RETURN n.delete")
      :read

      iex> Aerotow.Statement.classify("MATCH (as) WHERE as DELETE as")
      :write
  """
  @spec classify(String.t()) :: :read | :write
  def classify(statement) do
    case describe(statement) do
      {:read, _} -> :read
      {:write, _} -> :write
    end
  end

  @doc """
  Whether `statement` provably reads.

      iex> Aerotow.Statement.read?("CALL pagerank(top: 10)")
      true

      iex> Aerotow.Statement.read?("CALL pagerank(top: 10, write: \\"rank\\")")
      false
  """
  @spec read?(String.t()) :: boolean()
  def read?(statement), do: classify(statement) == :read

  @doc """
  `:ok` for a statement that reads. Otherwise an error that says what kind of
  statement it is and that writes go through `Aerotow.run/5`.

      iex> Aerotow.Statement.check_read("STATS")
      :ok

      iex> Aerotow.Statement.check_read("MATCH (n:Person) SET n.seen = true")
      {:error, "MATCH ... SET is not a read: only statements that read are taken here, and writes go through Aerotow.run/5"}
  """
  @spec check_read(String.t()) :: :ok | {:error, String.t()}
  def check_read(statement) do
    case describe(statement) do
      {:read, _} ->
        :ok

      {:write, what} ->
        {:error,
         what <>
           " is not a read: only statements that read are taken here, and writes go through Aerotow.run/5"}
    end
  end

  @doc """
  The built-in algorithms this module knows, aliases included. A `CALL` of
  one of them reads unless it is given `write:`; a `CALL` of any other name
  is a write.
  """
  @spec algorithms() :: [String.t()]
  def algorithms, do: @algorithms

  @doc """
  What this module knows of the `context` extension: the procedures that
  read, those that write, and its functions (which read). A procedure or
  function of any other extension is a write.
  """
  @spec context_members() :: %{
          reads: [String.t()],
          writes: [String.t()],
          functions: [String.t()]
        }
  def context_members,
    do: %{reads: @context_reads, writes: @context_writes, functions: @context_functions}

  # {:read | :write, what}: the class, and a phrase for the kind of statement
  # it is, which check_read/1 puts in its message.
  defp describe(statement) when is_binary(statement) do
    cond do
      byte_size(statement) > @max_bytes ->
        {:write, "a statement longer than #{@max_bytes} bytes"}

      not String.valid?(statement) ->
        {:write, "a statement that is not UTF-8"}

      true ->
        case tokens(statement, true) do
          {:ok, []} -> {:write, "an empty statement"}
          {:ok, ["explain" | _]} -> explain(statement)
          {:ok, toks} -> parse(toks)
          {:error, why} -> refused(why)
        end
    end
  end

  defp describe(_other), do: {:write, "something that is not a string"}

  # Errors are a reason glider would give for refusing the statement, or
  # {:write, what} for a statement glider might take but this module does not.
  defp refused({:write, what}), do: {:write, what}
  defp refused(why), do: {:write, "a statement glider would refuse (#{why})"}

  # Glider's EXPLAIN does not parse the tokens after it: it parses the source
  # again from 7 bytes past its first non-blank character. That is the
  # statement after EXPLAIN only when EXPLAIN is spelled out right there.
  defp explain(statement) do
    with <<word::binary-size(7), rest::binary>> <- trim_leading(statement),
         "explain" <- key(word) do
      case tokens(rest, false) do
        {:ok, []} -> {:write, "EXPLAIN of nothing"}
        {:ok, ["explain" | _]} -> {:write, "EXPLAIN of EXPLAIN"}
        {:ok, toks} -> toks |> parse() |> explained()
        {:error, why} -> why |> refused() |> explained()
      end
    else
      _ ->
        {:write,
         "EXPLAIN after a comment, a ';' or a backtick, which glider parses from the wrong place"}
    end
  end

  defp explained({class, what}), do: {class, "EXPLAIN of " <> what}

  # ------------------------------------------------------------------ tokens

  # Tokens as glider's lexer makes them:
  #
  #   "match", "n" …       a name, bare or in backticks, in ASCII lower case
  #                        (kept as written when it is longer than @max_key)
  #   :"(", :"->" …        a symbol
  #   :str, :int, :float   a literal; what is in it never decides anything
  #   :param               a $parameter, which glider replaces by its value
  #
  # `params?` is false for the statement inside EXPLAIN, which glider parses
  # without parameters. A name with characters outside ASCII is checked
  # afterwards against the classes glider uses (Rust's is_alphabetic and
  # is_alphanumeric), once for the whole statement.
  #
  # The lexer walks the statement once, passing the rest along in tail calls;
  # `pos` is where the rest starts in `src`, for cutting a name or a number
  # out of it.
  defp tokens(text, params?) do
    with {:ok, toks, wide} <- lex(text, text, 0, [], :none, [], params?),
         :ok <- check_wide(wide),
         do: {:ok, toks}
  end

  defguardp space(c) when c in [?\s, ?\t, ?\n, ?\v, ?\f, ?\r]
  defguardp name_start(c) when c in ?a..?z or c in ?A..?Z or c == ?_
  defguardp name_char(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_
  defguardp digit(c) when c in ?0..?9

  # `last` is what the previous token was (:none, :sym or :value): glider
  # reads `-1` as a negative number only at the start or after a symbol.
  defp lex(<<>>, _src, _pos, acc, _last, wide, _params?), do: {:ok, Enum.reverse(acc), wide}

  # White_Space, which is what Rust's char::is_whitespace, and so glider, skips.
  defp lex(<<c, rest::binary>>, src, pos, acc, last, wide, params?) when space(c),
    do: lex(rest, src, pos + 1, acc, last, wide, params?)

  defp lex(<<0xC2, c, rest::binary>>, src, pos, acc, last, wide, params?)
       when c == 0x85 or c == 0xA0,
       do: lex(rest, src, pos + 2, acc, last, wide, params?)

  defp lex(<<0xE1, 0x9A, 0x80, rest::binary>>, src, pos, acc, last, wide, params?),
    do: lex(rest, src, pos + 3, acc, last, wide, params?)

  defp lex(<<0xE2, 0x80, c, rest::binary>>, src, pos, acc, last, wide, params?)
       when c in 0x80..0x8A or c in [0xA8, 0xA9, 0xAF],
       do: lex(rest, src, pos + 3, acc, last, wide, params?)

  defp lex(<<0xE2, 0x81, 0x9F, rest::binary>>, src, pos, acc, last, wide, params?),
    do: lex(rest, src, pos + 3, acc, last, wide, params?)

  defp lex(<<0xE3, 0x80, 0x80, rest::binary>>, src, pos, acc, last, wide, params?),
    do: lex(rest, src, pos + 3, acc, last, wide, params?)

  # A comment runs to "\n" and no further.
  defp lex(<<?/, ?/, rest::binary>>, src, pos, acc, last, wide, params?) do
    case :binary.match(rest, "\n") do
      {at, 1} ->
        rest = binary_part(rest, at, byte_size(rest) - at)
        lex(rest, src, pos + 2 + at, acc, last, wide, params?)

      :nomatch ->
        lex(<<>>, src, byte_size(src), acc, last, wide, params?)
    end
  end

  # A name starts with a letter or '_'. Any character outside ASCII that is
  # not whitespace is taken into one here and checked in check_wide/1.
  defp lex(<<c, rest::binary>>, src, pos, acc, _last, wide, params?) when name_start(c),
    do: word(rest, src, pos, pos + 1, :name, acc, wide, params?)

  defp lex(<<c, rest::binary>>, src, pos, acc, _last, wide, params?) when c >= 0x80,
    do: word(rest, src, pos, pos + 1, :wide_name, acc, wide, params?)

  defp lex(<<c, rest::binary>>, src, pos, acc, _last, wide, params?) when digit(c),
    do: number(rest, src, pos, pos + 1, acc, wide, params?)

  defp lex(<<?-, c, rest::binary>>, src, pos, acc, last, wide, params?)
       when digit(c) and last != :value,
       do: number(rest, src, pos, pos + 2, acc, wide, params?)

  defp lex(<<q, rest::binary>>, src, pos, acc, _last, wide, params?) when q == ?" or q == ?',
    do: string(rest, src, pos + 1, q, acc, wide, params?)

  defp lex(<<?$, rest::binary>>, src, pos, acc, _last, wide, true),
    do: word(rest, src, pos + 1, pos + 1, :param, acc, wide, true)

  defp lex(<<?$, _::binary>>, _src, _pos, _acc, _last, _wide, false),
    do: {:error, "a parameter after EXPLAIN, which glider parses without parameters"}

  # A name in backticks may hold anything but a backtick.
  defp lex(<<?`, rest::binary>>, src, pos, acc, _last, wide, params?) do
    case :binary.match(rest, "`") do
      {at, 1} ->
        <<text::binary-size(^at), ?`, rest::binary>> = rest
        lex(rest, src, pos + at + 2, [key(text) | acc], :value, wide, params?)

      :nomatch ->
        {:error,
         {:write, "a backtick name with no closing backtick, which glider takes to the end"}}
    end
  end

  defp lex(<<?;, rest::binary>>, src, pos, acc, last, wide, params?),
    do: lex(rest, src, pos + 1, acc, last, wide, params?)

  defp lex(<<?-, ?>, rest::binary>>, src, pos, acc, _last, wide, params?),
    do: lex(rest, src, pos + 2, [:-> | acc], :sym, wide, params?)

  defp lex(<<?<, ?-, rest::binary>>, src, pos, acc, _last, wide, params?),
    do: lex(rest, src, pos + 2, [:<- | acc], :sym, wide, params?)

  defp lex(<<?<, ?>, rest::binary>>, src, pos, acc, _last, wide, params?),
    do: lex(rest, src, pos + 2, [:<> | acc], :sym, wide, params?)

  defp lex(<<?<, ?=, rest::binary>>, src, pos, acc, _last, wide, params?),
    do: lex(rest, src, pos + 2, [:<= | acc], :sym, wide, params?)

  defp lex(<<?>, ?=, rest::binary>>, src, pos, acc, _last, wide, params?),
    do: lex(rest, src, pos + 2, [:>= | acc], :sym, wide, params?)

  defp lex(<<?!, ?=, rest::binary>>, src, pos, acc, _last, wide, params?),
    do: lex(rest, src, pos + 2, [:!= | acc], :sym, wide, params?)

  defp lex(<<?., ?., rest::binary>>, src, pos, acc, _last, wide, params?),
    do: lex(rest, src, pos + 2, [:.. | acc], :sym, wide, params?)

  defp lex(<<c, rest::binary>>, src, pos, acc, _last, wide, params?)
       when c in ~c"(){}[]:,.=<>*-+/|!",
       do: lex(rest, src, pos + 1, [symbol(c) | acc], :sym, wide, params?)

  defp lex(<<c::utf8, _::binary>>, _src, _pos, _acc, _last, _wide, _params?),
    do: {:error, "unexpected character #{inspect(<<c::utf8>>)}"}

  defp symbol(?(), do: :"("
  defp symbol(?)), do: :")"
  defp symbol(?{), do: :"{"
  defp symbol(?}), do: :"}"
  defp symbol(?[), do: :"["
  defp symbol(?]), do: :"]"
  defp symbol(?:), do: :":"
  defp symbol(?,), do: :","
  defp symbol(?.), do: :.
  defp symbol(?=), do: :=
  defp symbol(?<), do: :<
  defp symbol(?>), do: :>
  defp symbol(?*), do: :*
  defp symbol(?-), do: :-
  defp symbol(?+), do: :+
  defp symbol(?/), do: :/
  defp symbol(?|), do: :|
  defp symbol(?!), do: :!

  # The rest of a name or of a parameter's name. A character outside ASCII
  # continues it unless it is whitespace; byte by byte is enough, since no
  # continuation byte starts a whitespace character.
  defp word(<<c, rest::binary>>, src, start, pos, kind, acc, wide, params?) when name_char(c),
    do: word(rest, src, start, pos + 1, kind, acc, wide, params?)

  defp word(<<c, _::binary>> = bin, src, start, pos, kind, acc, wide, params?) when c >= 0x80 do
    case space_size(bin) do
      0 ->
        <<_, rest::binary>> = bin
        word(rest, src, start, pos + 1, widen(kind), acc, wide, params?)

      _ ->
        word_end(bin, src, start, pos, kind, acc, wide, params?)
    end
  end

  defp word(rest, src, start, pos, kind, acc, wide, params?),
    do: word_end(rest, src, start, pos, kind, acc, wide, params?)

  # :wide_name and :wide_param have characters outside ASCII, for check_wide/1.
  defp widen(:name), do: :wide_name
  defp widen(:param), do: :wide_param
  defp widen(wide_kind), do: wide_kind

  defp word_end(rest, src, start, pos, kind, acc, wide, params?)
       when kind in [:name, :wide_name] do
    name = key(binary_part(src, start, pos - start))
    wide = if kind == :wide_name, do: [{:name, name} | wide], else: wide
    lex(rest, src, pos, [name | acc], :value, wide, params?)
  end

  defp word_end(_rest, _src, start, start, :param, _acc, _wide, _params?),
    do: {:error, "expected a parameter name after $"}

  defp word_end(rest, src, start, pos, kind, acc, wide, params?) do
    wide =
      if kind == :wide_param,
        do: [{:param, binary_part(src, start, pos - start)} | wide],
        else: wide

    lex(rest, src, pos, [:param | acc], :value, wide, params?)
  end

  # A backslash takes the character after it, whatever it is.
  defp string(<<?\\, _, rest::binary>>, src, pos, q, acc, wide, params?),
    do: string(rest, src, pos + 2, q, acc, wide, params?)

  defp string(<<q, rest::binary>>, src, pos, q, acc, wide, params?),
    do: lex(rest, src, pos + 1, [:str | acc], :value, wide, params?)

  defp string(<<_, rest::binary>>, src, pos, q, acc, wide, params?),
    do: string(rest, src, pos + 1, q, acc, wide, params?)

  defp string(<<>>, _src, _pos, _q, _acc, _wide, _params?), do: {:error, "unterminated string"}

  # Glider takes digits, '.', 'e' and 'E' after an optional '-', stopping
  # before "..", and parses that as an i64 or failing that an f64.
  defp number(<<?., ?., rest::binary>>, src, start, pos, acc, wide, params?) do
    with {:ok, kind} <- number_kind(binary_part(src, start, pos - start)),
         do: lex(rest, src, pos + 2, [:.., kind | acc], :sym, wide, params?)
  end

  defp number(<<c, rest::binary>>, src, start, pos, acc, wide, params?)
       when digit(c) or c in [?., ?e, ?E],
       do: number(rest, src, start, pos + 1, acc, wide, params?)

  defp number(rest, src, start, pos, acc, wide, params?) do
    with {:ok, kind} <- number_kind(binary_part(src, start, pos - start)),
         do: lex(rest, src, pos, [kind | acc], :value, wide, params?)
  end

  defp number_kind(text) do
    {negative?, digits} =
      case text do
        "-" <> digits -> {true, digits}
        digits -> {false, digits}
      end

    case shape(digits, :start) do
      :integer -> {:ok, if(fits_i64?(digits, negative?), do: :int, else: :float)}
      :float -> {:ok, :float}
      :error -> {:error, "bad number #{shown(text)}"}
    end
  end

  # [0-9]+(\.[0-9]*)?([eE][0-9]+)?: what Rust's f64 parse takes from these
  # characters, and an integer when there is no '.' and no exponent.
  defp shape(<<c, rest::binary>>, state) when digit(c) and state in [:start, :int],
    do: shape(rest, :int)

  defp shape(<<?., rest::binary>>, :int), do: shape(rest, :frac)
  defp shape(<<c, rest::binary>>, :frac) when digit(c), do: shape(rest, :frac)

  defp shape(<<e, c, rest::binary>>, state)
       when e in [?e, ?E] and digit(c) and state in [:int, :frac],
       do: shape(rest, :exp)

  defp shape(<<c, rest::binary>>, :exp) when digit(c), do: shape(rest, :exp)
  defp shape(<<>>, :int), do: :integer
  defp shape(<<>>, state) when state in [:frac, :exp], do: :float
  defp shape(_bin, _state), do: :error

  defp fits_i64?(digits, negative?) do
    digits = trim_zeros(digits)
    limit = if negative?, do: "9223372036854775808", else: "9223372036854775807"
    byte_size(digits) < 19 or (byte_size(digits) == 19 and digits <= limit)
  end

  defp trim_zeros("0" <> rest), do: trim_zeros(rest)
  defp trim_zeros(digits), do: digits

  # The bytes of the White_Space character `bin` starts with, or 0.
  defp space_size(<<c, _::binary>>) when space(c), do: 1
  defp space_size(<<0xC2, c, _::binary>>) when c == 0x85 or c == 0xA0, do: 2
  defp space_size(<<0xE1, 0x9A, 0x80, _::binary>>), do: 3

  defp space_size(<<0xE2, 0x80, c, _::binary>>) when c in 0x80..0x8A or c in [0xA8, 0xA9, 0xAF],
    do: 3

  defp space_size(<<0xE2, 0x81, 0x9F, _::binary>>), do: 3
  defp space_size(<<0xE3, 0x80, 0x80, _::binary>>), do: 3
  defp space_size(_bin), do: 0

  defp trim_leading(bin) do
    case space_size(bin) do
      0 -> bin
      n -> trim_leading(binary_part(bin, n, byte_size(bin) - n))
    end
  end

  # Glider takes a character outside ASCII into a name only when Rust calls
  # it alphabetic, or numeric after a name's first character (a parameter's
  # name may start with either). The regex engine is asked once for each
  # distinct character.
  defp check_wide([]), do: :ok

  defp check_wide(runs) do
    classes = {~r/\A\p{Alphabetic}\z/u, ~r/\A\p{N}\z/u}

    result =
      Enum.reduce_while(runs, %{}, fn {kind, text}, seen ->
        case wide_chars(text, kind == :param, seen, classes) do
          {:ok, seen} -> {:cont, seen}
          :error -> {:halt, {:error, text}}
        end
      end)

    case result do
      {:error, text} -> {:error, "a character glider does not take in a name, in #{shown(text)}"}
      _seen -> :ok
    end
  end

  defp wide_chars(<<c, rest::binary>>, _numeric?, seen, classes) when c < 0x80,
    do: wide_chars(rest, true, seen, classes)

  defp wide_chars(<<c::utf8, rest::binary>>, numeric?, seen, classes) do
    {class, seen} = char_class(c, seen, classes)

    if class == :alphabetic or (class == :numeric and numeric?),
      do: wide_chars(rest, true, seen, classes),
      else: :error
  end

  defp wide_chars(<<>>, _numeric?, seen, _classes), do: {:ok, seen}

  defp char_class(c, seen, {alphabetic, numeric}) do
    case seen do
      %{^c => class} ->
        {class, seen}

      _ ->
        char = <<c::utf8>>

        class =
          cond do
            Regex.match?(alphabetic, char) -> :alphabetic
            Regex.match?(numeric, char) -> :numeric
            true -> :other
          end

        {class, Map.put(seen, c, class)}
    end
  end

  defp key(text) when byte_size(text) > @max_key, do: text
  defp key(text), do: if(lower?(text), do: :binary.copy(text), else: lowered(text))

  defp lower?(<<c, _::binary>>) when c in ?A..?Z, do: false
  defp lower?(<<_, rest::binary>>), do: lower?(rest)
  defp lower?(<<>>), do: true

  defp lowered(text), do: for(<<c <- text>>, into: "", do: <<lower(c)>>)

  defp lower(c) when c in ?A..?Z, do: c + 32
  defp lower(c), do: c

  defp ascii?(<<c, rest::binary>>) when c < 0x80, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_text), do: false

  # ---------------------------------------------------------------- statements

  # Each parser below mirrors the glider function of the same purpose and
  # returns {:ok, …, rest} or {:error, why}. A name is a binary in a token
  # list, so `name when is_binary(name)` is glider's `p.ident()`.

  defp parse(toks) do
    case stmt(toks) do
      {:ok, found, []} -> found
      {:ok, _found, [tok | _]} -> refused("#{shown_token(tok)} after the end of the statement")
      {:error, why} -> refused(why)
    end
  end

  defp stmt(["match" | toks]) do
    with {:ok, rest} <- patterns(toks),
         {:ok, rest} <- where(rest),
         do: tail(rest)
  end

  defp stmt(["create", "extension" | toks]),
    do: written(if_exists(toks, ["not", "exists"]), "CREATE EXTENSION")

  defp stmt(["create", "index" | toks]), do: written(index_target(toks), "CREATE INDEX")
  defp stmt(["create" | toks]), do: written(patterns(toks), "CREATE")
  defp stmt(["call" | toks]), do: call(toks)
  defp stmt(["index" | toks]), do: written(index_target(toks), "INDEX")

  defp stmt(["drop", "extension" | toks]),
    do: written(if_exists(toks, ["exists"]), "DROP EXTENSION")

  defp stmt(["drop", "index" | toks]), do: written(index_target(toks), "DROP INDEX")
  defp stmt(["drop" | _]), do: {:error, "expected INDEX"}

  defp stmt(["alter", "extension", name, "update" | rest]) when is_binary(name),
    do: {:ok, {:write, "ALTER EXTENSION"}, rest}

  defp stmt(["alter" | _]), do: {:error, "expected EXTENSION <name> UPDATE"}
  defp stmt(["show", "extensions" | rest]), do: read(rest, "SHOW EXTENSIONS")
  defp stmt(["show" | _]), do: {:error, "expected EXTENSIONS"}
  defp stmt(["stats" | rest]), do: read(rest, "STATS")
  defp stmt(["schema" | rest]), do: read(rest, "SCHEMA")
  defp stmt(["help" | rest]), do: read(rest, "HELP")

  defp stmt([word | rest]) when word in ~w(compact clear begin commit rollback),
    do: {:ok, {:write, String.upcase(word)}, rest}

  defp stmt(_toks), do: {:error, "not a statement glider knows"}

  defp read(rest, what), do: {:ok, {:read, what}, rest}

  defp written({:ok, rest}, what), do: {:ok, {:write, what}, rest}
  defp written({:error, _} = error, _what), do: error

  # [IF NOT EXISTS] name, or [IF EXISTS] name.
  defp if_exists(["if" | toks], words) do
    case Enum.reduce_while(words, {:ok, toks}, &expect_word/2) do
      {:ok, toks} -> ident(toks)
      error -> error
    end
  end

  defp if_exists(toks, _words), do: ident(toks)

  defp expect_word(word, {:ok, [word | rest]}), do: {:cont, {:ok, rest}}
  defp expect_word(word, {:ok, _}), do: {:halt, {:error, "expected #{String.upcase(word)}"}}

  defp index_target(["on" | toks]), do: index_label(toks)
  defp index_target(toks), do: index_label(toks)

  defp index_label([:":", label, :"(", key, :")" | rest])
       when is_binary(label) and is_binary(key),
       do: {:ok, rest}

  defp index_label(_toks), do: {:error, "expected :Label(key)"}

  defp where(["where" | toks]), do: value(toks)
  defp where(toks), do: {:ok, toks}

  defp tail(["return" | toks]), do: returning(toks)
  defp tail(["set" | toks]), do: written(set_items(toks), "MATCH ... SET")
  defp tail(["remove" | toks]), do: written(set_items(toks), "MATCH ... REMOVE")
  defp tail(["detach", "delete" | toks]), do: written(names(toks), "MATCH ... DETACH DELETE")
  defp tail(["detach" | _]), do: {:error, "expected DELETE"}
  defp tail(["delete" | toks]), do: written(names(toks), "MATCH ... DELETE")
  defp tail(["create" | toks]), do: written(patterns(toks), "MATCH ... CREATE")
  defp tail([]), do: {:ok, {:read, "MATCH with no RETURN (a count)"}, []}
  defp tail(_toks), do: {:error, "expected RETURN, SET, REMOVE, DELETE or CREATE"}

  defp returning(["distinct" | toks]), do: returned(toks)
  defp returning(toks), do: returned(toks)

  defp returned(toks) do
    with {:ok, rest} <- return_items(toks),
         {:ok, rest} <- order_by(rest),
         {:ok, rest} <- skip_limit(rest),
         do: read(rest, "MATCH ... RETURN")
  end

  defp return_items([:* | rest]), do: {:ok, rest}
  defp return_items(toks), do: item_list(toks)

  defp item_list(toks) do
    with {:ok, rest} <- value(toks),
         {:ok, rest} <- as(rest) do
      case rest do
        [:"," | rest] -> item_list(rest)
        rest -> {:ok, rest}
      end
    end
  end

  defp as(["as" | toks]), do: ident(toks)
  defp as(toks), do: {:ok, toks}

  defp order_by(["order", "by" | toks]), do: order_items(toks)
  defp order_by(["order" | _]), do: {:error, "expected BY"}
  defp order_by(toks), do: {:ok, toks}

  defp order_items(toks) do
    with {:ok, rest} <- value(toks) do
      rest =
        case rest do
          [direction | rest] when direction in ["desc", "asc"] -> rest
          rest -> rest
        end

      case rest do
        [:"," | rest] -> order_items(rest)
        rest -> {:ok, rest}
      end
    end
  end

  # A count after SKIP or LIMIT is a non-negative integer; a parameter may be one.
  defp skip_limit([word, count | rest]) when word in ["skip", "limit"] do
    if count in [:int, :param],
      do: skip_limit(rest),
      else: {:error, "expected a non-negative integer"}
  end

  defp skip_limit([word]) when word in ["skip", "limit"],
    do: {:error, "expected a non-negative integer"}

  defp skip_limit(toks), do: {:ok, toks}

  defp set_items([var, :":" | toks]) when is_binary(var) do
    with {:ok, rest} <- ident(toks), do: more_set_items(rest)
  end

  defp set_items([var, :., key, := | toks]) when is_binary(var) and is_binary(key) do
    with {:ok, rest} <- value(toks), do: more_set_items(rest)
  end

  defp set_items([var, :., key | rest]) when is_binary(var) and is_binary(key),
    do: more_set_items(rest)

  defp set_items([var, :. | _]) when is_binary(var), do: {:error, "expected an identifier"}
  defp set_items([var | _]) when is_binary(var), do: {:error, "expected '.'"}
  defp set_items(_toks), do: {:error, "expected an identifier"}

  defp more_set_items([:"," | toks]), do: set_items(toks)
  defp more_set_items(toks), do: {:ok, toks}

  defp names([name, :"," | toks]) when is_binary(name), do: names(toks)
  defp names([name | rest]) when is_binary(name), do: {:ok, rest}
  defp names(_toks), do: {:error, "expected an identifier"}

  defp ident([name | rest]) when is_binary(name), do: {:ok, rest}
  defp ident(_toks), do: {:error, "expected an identifier"}

  defp expect([sym | rest], sym), do: {:ok, rest}
  defp expect(_toks, sym), do: {:error, "expected '#{sym}'"}

  # ---------------------------------------------------------------------- CALL

  defp call(toks) do
    with {:ok, name, rest} <- call_name(toks),
         {:ok, args, rest} <- call_args(rest),
         do: {:ok, call_kind(name, args), rest}
  end

  defp call_name([ns, :., member | rest]) when is_binary(ns) and is_binary(member),
    do: {:ok, {ns, member}, rest}

  defp call_name([name, :. | _]) when is_binary(name), do: {:error, "expected an identifier"}
  defp call_name([name | rest]) when is_binary(name), do: {:ok, name, rest}
  defp call_name(_toks), do: {:error, "expected an identifier"}

  defp call_args([:"(" | toks]), do: args(toks, [])
  defp call_args(toks), do: {:ok, [], toks}

  # Glider's loop: until ')', `name: constant` followed by ',' or ')'. A
  # trailing comma is allowed.
  defp args([:")" | rest], acc), do: {:ok, acc, rest}

  defp args([name, :":" | toks], acc) when is_binary(name) do
    with {:ok, {kind, _}, rest} <- expr(toks, 0),
         :ok <- constant(kind) do
      case rest do
        [:"," | rest] -> args(rest, [name | acc])
        [:")" | _] -> args(rest, [name | acc])
        _ -> {:error, "expected ',' or ')' in CALL arguments"}
      end
    end
  end

  defp args([name | _], _acc) when is_binary(name), do: {:error, "expected ':'"}
  defp args(_toks, _acc), do: {:error, "expected an identifier"}

  defp constant(:expr), do: {:error, "expected a constant value"}
  defp constant(_kind), do: :ok

  defp call_kind({ns, member}, args) do
    cond do
      String.contains?(ns, ".") or String.contains?(member, ".") ->
        {:write, "a CALL of a quoted name with a dot in it, which glider takes as a procedure"}

      ns == "context" and member in @context_writes ->
        {:write, "CALL context." <> member}

      ns != "context" or member not in @context_reads ->
        {:write, "a CALL of a procedure aerotow does not know (#{shown(ns <> "." <> member)})"}

      true ->
        with_args("CALL context." <> member, args)
    end
  end

  defp call_kind(name, args) do
    cond do
      String.contains?(name, ".") ->
        {:write, "a CALL of a quoted name with a dot in it, which glider takes as a procedure"}

      name not in @algorithms ->
        {:write, "a CALL of an algorithm aerotow does not know (#{shown(name)})"}

      true ->
        with_args("CALL " <> name, args)
    end
  end

  # An argument called `write`, in any case: glider lowercases argument
  # names. One named outside ASCII is lowercased by Unicode's rules, which
  # this module does not follow, so it might be `write` too.
  defp with_args(call, args) do
    cond do
      "write" in args -> {:write, call <> " with a write: argument"}
      not Enum.all?(args, &ascii?/1) -> {:write, call <> " with an argument named outside ASCII"}
      true -> {:read, call}
    end
  end

  # ------------------------------------------------------------------ patterns

  defp patterns(toks) do
    with {:ok, rest} <- node_pattern(toks),
         {:ok, rest} <- links(rest) do
      case rest do
        [:"," | rest] -> patterns(rest)
        rest -> {:ok, rest}
      end
    end
  end

  defp node_pattern([:"(" | toks]) do
    toks =
      case toks do
        [var | rest] when is_binary(var) -> rest
        toks -> toks
      end

    with {:ok, rest} <- labels(toks),
         {:ok, rest} <- props(rest),
         do: expect(rest, :")")
  end

  defp node_pattern(_toks), do: {:error, "expected '('"}

  defp labels([:":" | toks]) do
    with {:ok, rest} <- ident(toks), do: labels(rest)
  end

  defp labels(toks), do: {:ok, toks}

  defp links([arrow | toks]) when arrow in [:<-, :-] do
    with {:ok, bound?, hops?, rest} <- relationship(toks),
         {:ok, rest} <- arrow_end(rest),
         :ok <- bindable(bound?, hops?),
         {:ok, rest} <- node_pattern(rest),
         do: links(rest)
  end

  defp links(toks), do: {:ok, toks}

  defp relationship([:"[" | toks]) do
    {bound?, toks} =
      case toks do
        [var | rest] when is_binary(var) -> {true, rest}
        toks -> {false, toks}
      end

    with {:ok, rest} <- types(toks),
         {hops?, rest} = hops(rest),
         {:ok, rest} <- props(rest),
         {:ok, rest} <- expect(rest, :"]"),
         do: {:ok, bound?, hops?, rest}
  end

  defp relationship(toks), do: {:ok, false, false, toks}

  # `:A|:B`: after a '|' the loop goes on only at another ':'.
  defp types([:":" | toks]) do
    case ident(toks) do
      {:ok, [:| | rest]} -> types(rest)
      other -> other
    end
  end

  defp types(toks), do: {:ok, toks}

  defp hops([:* | toks]) do
    case skip_int(toks) do
      [:.. | rest] -> {true, skip_int(rest)}
      toks -> {true, toks}
    end
  end

  defp hops(toks), do: {false, toks}

  defp skip_int([count | rest]) when count in [:int, :param], do: rest
  defp skip_int(toks), do: toks

  defp arrow_end([arrow | rest]) when arrow in [:->, :-], do: {:ok, rest}
  defp arrow_end(_toks), do: {:error, "expected '-'"}

  defp bindable(true, true),
    do: {:error, "variable-length patterns can't bind a relationship variable"}

  defp bindable(_bound?, _hops?), do: :ok

  defp props([:"{", :"}" | rest]), do: {:ok, rest}
  defp props([:"{" | toks]), do: prop_entries(toks)
  defp props(toks), do: {:ok, toks}

  # A key is a name or a string (or a parameter standing for one).
  defp prop_entries([key, :":" | toks]) when is_binary(key) or key in [:str, :param] do
    with {:ok, rest} <- value(toks) do
      case rest do
        [:"," | rest] -> prop_entries(rest)
        rest -> expect(rest, :"}")
      end
    end
  end

  defp prop_entries(_toks), do: {:error, "expected a property name and ':'"}

  # --------------------------------------------------------------- expressions

  # Glider's precedence: OR < AND < NOT < comparison < additive <
  # multiplicative < subscripts < primary. Each step returns {kind, height}:
  # kind is what glider's const_value makes of the expression (:num, :const,
  # :param, or :expr for one that is not a constant), and height is the
  # depth of the tree glider builds, which it evaluates and frees
  # recursively. `depth` counts the levels the parser has recursed into.

  defp value(toks) do
    with {:ok, _, rest} <- expr(toks, 0), do: {:ok, rest}
  end

  defp expr(_toks, depth) when depth > @max_nesting, do: too_deep()

  # An operand, or a name and a property, followed by nothing that can go on
  # with an expression is the whole expression: glider's descent through the
  # levels below would return just that. Taking it here keeps a long list
  # of short expressions quick.
  defp expr([name, :., key | rest] = toks, depth)
       when is_binary(name) and is_binary(key) and name not in ["not", "true", "false", "null"] do
    case rest do
      [next | _] when next in @goes_on -> descend(toks, depth)
      rest -> {:ok, {:expr, 1}, rest}
    end
  end

  defp expr([tok | rest] = toks, depth) do
    case {operand(tok), rest} do
      {nil, _} -> descend(toks, depth)
      {_, [next | _]} when next in @goes_on -> descend(toks, depth)
      {found, rest} -> {:ok, found, rest}
    end
  end

  defp expr([], depth), do: descend([], depth)

  defp operand(literal) when literal in [:int, :float], do: {:num, 1}
  defp operand(:str), do: {:const, 1}
  defp operand(:param), do: {:param, 1}
  defp operand(word) when word in ["true", "false"], do: {:num, 1}
  defp operand("null"), do: {:const, 1}
  defp operand("not"), do: nil
  defp operand(name) when is_binary(name), do: {:expr, 1}
  defp operand(_sym), do: nil

  defp descend(toks, depth) do
    case or_expr(toks, depth) do
      {:ok, {_, height}, _} when height > @max_height ->
        {:error, {:write, "a statement with an expression more than #{@max_height} levels deep"}}

      result ->
        result
    end
  end

  defp too_deep,
    do: {:error, {:write, "a statement nested more than #{@max_nesting} levels deep"}}

  defp or_expr(toks, depth) do
    with {:ok, left, rest} <- and_expr(toks, depth), do: or_more(rest, left, depth)
  end

  defp or_more(["or" | toks], left, depth) do
    with {:ok, right, rest} <- and_expr(toks, depth),
         do: or_more(rest, join(left, right), depth)
  end

  defp or_more(toks, left, _depth), do: {:ok, left, toks}

  defp and_expr(toks, depth) do
    with {:ok, left, rest} <- not_expr(toks, depth), do: and_more(rest, left, depth)
  end

  defp and_more(["and" | toks], left, depth) do
    with {:ok, right, rest} <- not_expr(toks, depth),
         do: and_more(rest, join(left, right), depth)
  end

  defp and_more(toks, left, _depth), do: {:ok, left, toks}

  defp not_expr([word | toks], depth) when word in ["not", :!], do: negated(toks, depth)
  defp not_expr(toks, depth), do: comparison(toks, depth)

  defp negated(_toks, depth) when depth >= @max_nesting, do: too_deep()

  defp negated(toks, depth) do
    with {:ok, inner, rest} <- not_expr(toks, depth + 1), do: {:ok, wrap(inner), rest}
  end

  defp comparison(toks, depth) do
    with {:ok, left, rest} <- additive(toks, depth), do: compare(rest, left, depth)
  end

  defp compare(["is", "not", "null" | rest], left, _depth), do: {:ok, wrap(left), rest}
  defp compare(["is", "null" | rest], left, _depth), do: {:ok, wrap(left), rest}
  defp compare(["is" | _], _left, _depth), do: {:error, "expected NULL"}
  defp compare(["in", :"[", :"]" | rest], left, _depth), do: {:ok, wrap(left), rest}

  defp compare(["in", :"[" | toks], left, depth) do
    with {:ok, items, rest} <- items(toks, depth + 1),
         {:ok, rest} <- expect(rest, :"]"),
         do: {:ok, join(left, items), rest}
  end

  # A list parameter is what glider puts after IN in place of `[...]`.
  defp compare(["in", :param | rest], left, _depth), do: {:ok, join(left, {:const, 2}), rest}
  defp compare(["in" | _], _left, _depth), do: {:error, "expected '['"}
  defp compare(["contains" | toks], left, depth), do: right_side(toks, left, depth)

  defp compare([word, "with" | toks], left, depth) when word in ["starts", "ends"],
    do: right_side(toks, left, depth)

  defp compare([word | _], _left, _depth) when word in ["starts", "ends"],
    do: {:error, "expected WITH"}

  defp compare([op | toks], left, depth) when op in [:<>, :!=, :<=, :>=, :=, :<, :>],
    do: right_side(toks, left, depth)

  defp compare(toks, left, _depth), do: {:ok, left, toks}

  defp right_side(toks, left, depth) do
    with {:ok, right, rest} <- additive(toks, depth), do: {:ok, join(left, right), rest}
  end

  defp additive(toks, depth) do
    with {:ok, left, rest} <- multiplicative(toks, depth), do: add_more(rest, left, depth)
  end

  defp add_more([:+ | toks], left, depth) do
    with {:ok, right, rest} <- multiplicative(toks, depth),
         do: add_more(rest, join(left, right), depth)
  end

  defp add_more([:- | toks], left, depth) do
    with {:ok, right, rest} <- multiplicative(toks, depth),
         do: add_more(rest, minus(left, right), depth)
  end

  defp add_more(toks, left, _depth), do: {:ok, left, toks}

  defp multiplicative(toks, depth) do
    with {:ok, left, rest} <- atom_expr(toks, depth), do: mul_more(rest, left, depth)
  end

  defp mul_more([op | toks], left, depth) when op in [:*, :/] do
    with {:ok, right, rest} <- atom_expr(toks, depth),
         do: mul_more(rest, join(left, right), depth)
  end

  defp mul_more(toks, left, _depth), do: {:ok, left, toks}

  defp atom_expr(toks, depth) do
    with {:ok, e, rest} <- primary(toks, depth), do: subscripts(rest, e, depth)
  end

  # `x[i]`, `x[a..b]`, `x[..b]`, `x[a..]`, `x[..]`, any number of them.
  defp subscripts([:"[", :.., :"]" | rest], e, depth), do: subscripts(rest, wrap(e), depth)

  defp subscripts([:"[", :.. | toks], e, depth) do
    with {:ok, last, rest} <- expr(toks, depth + 1),
         {:ok, rest} <- expect(rest, :"]"),
         do: subscripts(rest, join(e, last), depth)
  end

  defp subscripts([:"[" | toks], e, depth) do
    with {:ok, first, rest} <- expr(toks, depth + 1) do
      case rest do
        [:.., :"]" | rest] ->
          subscripts(rest, join(e, first), depth)

        [:.. | rest] ->
          with {:ok, last, rest} <- expr(rest, depth + 1),
               {:ok, rest} <- expect(rest, :"]"),
               do: subscripts(rest, join(join(e, first), last), depth)

        rest ->
          with {:ok, rest} <- expect(rest, :"]"),
               do: subscripts(rest, join(e, first), depth)
      end
    end
  end

  defp subscripts(toks, e, _depth), do: {:ok, e, toks}

  defp primary([literal | rest], _depth) when literal in [:int, :float],
    do: {:ok, {:num, 1}, rest}

  defp primary([:str | rest], _depth), do: {:ok, {:const, 1}, rest}
  defp primary([:param | rest], _depth), do: {:ok, {:param, 1}, rest}

  defp primary([:"(" | toks], depth) do
    with {:ok, e, rest} <- expr(toks, depth + 1),
         {:ok, rest} <- expect(rest, :")"),
         do: {:ok, e, rest}
  end

  defp primary([:"[", :"]" | rest], _depth), do: {:ok, {:const, 1}, rest}

  defp primary([:"[" | toks], depth) do
    with {:ok, {kind, height}, rest} <- items(toks, depth + 1),
         {:ok, rest} <- expect(rest, :"]"),
         do: {:ok, {kind, height + 1}, rest}
  end

  # `-x` is glider's `0 - x`.
  defp primary([:- | _], depth) when depth >= @max_nesting, do: too_deep()

  defp primary([:- | toks], depth) do
    with {:ok, e, rest} <- atom_expr(toks, depth + 1), do: {:ok, minus({:num, 1}, e), rest}
  end

  # true, false and null are literals before anything else, even before '('.
  defp primary([word | rest], _depth) when word in ["true", "false"], do: {:ok, {:num, 1}, rest}
  defp primary(["null" | rest], _depth), do: {:ok, {:const, 1}, rest}

  defp primary([name, :"(" | toks], depth) when is_binary(name) do
    if String.contains?(name, ".") do
      {:error,
       {:write,
        "a call of a quoted function name with a dot in it, which glider takes as an extension function"}}
    else
      function_args(toks, depth, true)
    end
  end

  defp primary(["context", :., function, :"(" | toks], depth) when function in @context_functions,
    do: function_args(toks, depth, false)

  defp primary([ns, :., function, :"(" | _], _depth) when is_binary(ns) and is_binary(function),
    do:
      {:error,
       {:write, "a call of a function aerotow does not know (#{shown(ns <> "." <> function)})"}}

  defp primary([name, :., key | rest], _depth) when is_binary(name) and is_binary(key),
    do: {:ok, {:expr, 1}, rest}

  defp primary([name, :. | _], _depth) when is_binary(name),
    do: {:error, "expected an identifier"}

  defp primary([name | rest], _depth) when is_binary(name), do: {:ok, {:expr, 1}, rest}
  defp primary([tok | _], _depth), do: {:error, "unexpected #{shown_token(tok)}"}
  defp primary([], _depth), do: {:error, "unexpected end of the statement"}

  # `f(*)` only for a plain function name; glider has no `*` for an
  # extension's functions.
  defp function_args([:*, :")" | rest], _depth, true), do: {:ok, {:expr, 2}, rest}
  defp function_args([:")" | rest], _depth, _star?), do: {:ok, {:expr, 1}, rest}

  defp function_args(toks, depth, _star?) do
    with {:ok, {_, height}, rest} <- items(toks, depth + 1),
         {:ok, rest} <- expect(rest, :")"),
         do: {:ok, {:expr, height + 1}, rest}
  end

  # One or more expressions separated by commas: a list's kind is :const
  # when every item is a constant.
  defp items(toks, depth), do: items(toks, depth, :const, 0)

  defp items(toks, depth, kind, height) do
    with {:ok, {item_kind, item_height}, rest} <- expr(toks, depth) do
      kind = if item_kind == :expr, do: :expr, else: kind
      height = max(height, item_height)

      case rest do
        [:"," | rest] -> items(rest, depth, kind, height)
        rest -> {:ok, {kind, height}, rest}
      end
    end
  end

  defp join({_, left}, {_, right}), do: {:expr, 1 + max(left, right)}
  defp wrap({_, height}), do: {:expr, height + 1}

  # const_value takes `a - b` of two numbers (booleans count) as a constant.
  defp minus({left_kind, left}, {right_kind, right}) do
    numbers? = left_kind in [:num, :param] and right_kind in [:num, :param]
    {if(numbers?, do: :num, else: :expr), 1 + max(left, right)}
  end

  # -------------------------------------------------------------------- words

  defp shown(text) when byte_size(text) > 40, do: inspect(String.slice(text, 0, 40) <> "...")
  defp shown(text), do: inspect(text)

  defp shown_token(name) when is_binary(name), do: shown(name)
  defp shown_token(:str), do: "a string"
  defp shown_token(:param), do: "a parameter"
  defp shown_token(literal) when literal in [:int, :float], do: "a number"
  defp shown_token(sym), do: inspect(Atom.to_string(sym))
end
