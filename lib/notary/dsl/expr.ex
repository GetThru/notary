defmodule Notary.DSL.Expr do
  @moduledoc """
  Translation of Elixir expressions to TLA+ expression terms.

  `Notary.DSL` collects the surface macros (`variable`, `action`,
  `invariant`, ...) into a description struct (`Notary.DSL.Description`);
  every guard, effect, and property body in it is translated here, one Elixir
  AST at a time, into a term (`t:t/0`) and rendered to TLA+ by `render/2`.

  The translation is deliberate and total over a small, chosen subset of
  Elixir: anything outside it raises `Notary.DSL.Error` quoting the offending
  code — a silent mistranslation would undermine the whole point of writing
  the spec in Elixir.

  ## Mapping to TLA+

  | Elixir | TLA+ |
  |---|---|
  | `1`, `true`, `"deposit"` | `1`, `TRUE`, `"deposit"` |
  | variable `count` | `count` |
  | `get(count)` | `count'` (the next-state value) |
  | `+ - *` | `+ - *` |
  | `/` `rem` | `\\div` `\\mod` |
  | `== != < > <= >=` | `= # < > <= >=` |
  | `and or not` | `/\\` `\\/` `~` |
  | `x in s` / `x not in s` | `x \\in s` / `x \\notin s` |
  | `if c do a else b end` | `IF c THEN a ELSE b` (else required) |
  | `[a, b]` / `{a, b}` | `<<a, b>>` (a sequence) |
  | `[a: 1]` / `%{a: 1}` | `[a |-> 1]` (a record) |
  | `a..b` | `a..b` (a set, in types/params) |
  | `unchanged(x)` / `unchanged([:x, :y])` | `UNCHANGED x` / `UNCHANGED <<x, y>>` |
  | `assign(x: e)` | `x' = e` |
  | `eventually/always/leads_to` | `<>` `[]` `~>` |
  | `enabled(Action)` | `ENABLED <<Action(..)>>_<vars>` |
  | `min/max/head/tail/length/...` | IF-expressions, `Head`/`Tail`/`Len`, ... |

  Guards describe the state *before* the step, so `get/1` is forbidden there
  (`guard/2` rejects it); an effect must say what changes — a body with no
  `assign/1` at all is rejected (`effect/2`).
  """

  alias Notary.DSL.Error

  @type t ::
          {:int, integer()}
          | {:bool, boolean()}
          | {:str, String.t()}
          | {:var, String.t()}
          | {:prime, String.t()}
          | {:op, atom(), [t()]}
          | {:call, String.t(), [t()]}
          | {:enum, [t()]}
          | {:record, %{String.t() => t()}}
          | {:seq, [t()]}
          | {:range, t(), t()}
          | {:unchanged, [String.t()]}
          | {:assign, %{String.t() => t()}}
          | {:temporal, atom(), [t()]}

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  @doc """
  Translates a guard (or any non-temporal state formula: invariant bodies,
  property sub-formulas). Guards may not reference primed variables — they
  speak about the state before the step.
  """
  @spec guard(Macro.t(), keyword()) :: t()
  def guard(ast, meta \\ []) do
    t = expr(ast, meta)

    case primed_vars(t, []) do
      [] ->
        t

      names ->
        raise Error,
          message:
            "Guards describe the state before the step, so they cannot reference a next value. " <>
              "Found get(#{names |> Enum.uniq() |> Enum.join("), get(")}) in: #{Macro.to_string(ast)}. " <>
              "Did you mean the variable without get/1?",
          meta: meta
    end
  end

  @doc "Like `guard/2` but allows temporal operators (for properties and liveness)."
  @spec formula(Macro.t(), keyword()) :: t()
  def formula(ast, meta \\ []), do: expr(ast, meta)

  @doc """
  Translates an action effect. The effect must say what changes: an
  `assign/1` (or `both/2`/`either/2` containing one) or an explicit
  `unchanged/1` must appear.
  """
  @spec effect(Macro.t(), keyword()) :: t()
  def effect(ast, meta) do
    t = expr(ast, meta)

    unless has_effect?(t) do
      raise Error,
        message:
          "An action's effect must say what changes: wrap the next state in assign(...) " <>
            "(e.g. `assign(count: count + 1)`) or state what stays with unchanged(...).\n\n" <>
            "Got: #{Macro.to_string(ast)}",
        meta: meta
    end

    t
  end

  # Inside an assign's value (the right side of x' = e), get(v) would render
  # as v' — but TLA+ evaluates the right side in the state before the step,
  # so a prime there is always wrong. The unprimed variable IS the current
  # value; reject get/1 so the misreading can't slip in.
  defp reject_primed_in_value!(changes, meta) do
    for {name, value} <- changes,
        found = primed_vars(value, []),
        found != [] do
      raise Error,
        message:
          "In `assign(#{name}: ...)`, the value describes the state before the step, so get(#{hd(found)}) " <>
            "is not allowed — write the variable name directly (#{hd(found)}), as TLA+ does on the right side of #{name}' = ....",
        meta: meta
    end
  end

  @doc "Translates an arbitrary value expression (type domains, parameter bounds, ...)."
  @spec value(Macro.t(), keyword()) :: t()
  def value(ast, meta \\ []), do: expr(ast, meta)

  # ---------------------------------------------------------------------------
  # Rendering (single-line; notary's emitter lays out clause chains)
  # ---------------------------------------------------------------------------

  @doc """
  Renders a translated term to TLA+ text. Chains (`:parallel`/`:choice`) are
  flattened and joined inline; `Notary.DSL.Description` converts top-level
  chains of a definition into the vertical `\\*`-aligned layout.
  """
  @spec render(t(), keyword()) :: String.t()
  def render(term, opts \\ [])

  def render({:int, n}, _opts), do: Integer.to_string(n)
  def render({:bool, true}, _opts), do: "TRUE"
  def render({:bool, false}, _opts), do: "FALSE"
  def render({:str, s}, _opts), do: inspect(s)
  def render({:var, name}, _opts), do: name
  def render({:prime, name}, _opts), do: name <> "'"

  def render({:call, name, []}, _opts), do: name

  def render({:call, name, args}, opts),
    do: "#{name}(#{args |> Enum.map(&render(&1, opts)) |> Enum.join(", ")})"

  def render({:enum, items}, opts),
    do: "{#{items |> Enum.map(&render(&1, opts)) |> Enum.join(", ")}}"

  def render({:seq, items}, opts),
    do: "<<#{items |> Enum.map(&render(&1, opts)) |> Enum.join(", ")}>>"

  def render({:record, fields}, opts) do
    fields
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k} |-> #{render(v, opts)}" end)
    |> then(&"[#{&1}]")
  end

  def render({:range, a, b}, opts), do: "#{render(a, opts)}..#{render(b, opts)}"

  def render({:unchanged, [one]}, _opts), do: "UNCHANGED #{one}"
  def render({:unchanged, many}, _opts), do: "UNCHANGED <<#{Enum.join(many, ", ")}>>"

  def render({:assign, changes}, opts) do
    changes
    |> Enum.sort()
    |> Enum.map_join(" /\\ ", fn {name, value} -> "#{name}' = #{render(value, opts)}" end)
  end

  def render({:temporal, :eventually, [inner]}, opts),
    do: "<>#{atomize(inner, opts)}"

  def render({:temporal, :always, [inner]}, opts),
    do: "[]#{atomize(inner, opts)}"

  def render({:temporal, :leads_to, [a, b]}, opts),
    do: "#{atomize(a, opts)} ~> #{atomize(b, opts)}"

  def render({:temporal, :enabled, [{:call, name, args}]}, opts) do
    rendered = args |> Enum.map(&render(&1, opts)) |> Enum.join(", ")
    vars = Keyword.fetch!(opts, :vars)
    "ENABLED <<#{name}(#{rendered})>>_#{vars_subscript(vars)}"
  end

  def render({:op, op, args}, opts), do: render_op(op, args, opts)

  defp render_op(:parallel, args, opts),
    do:
      args
      |> Enum.flat_map(&flatten(:parallel, &1))
      |> Enum.map_join(" /\\ ", &chain_item(&1, opts))

  defp render_op(:choice, args, opts),
    do:
      args
      |> Enum.flat_map(&flatten(:choice, &1))
      |> Enum.map_join(" \\/ ", &chain_item(&1, opts))

  defp render_op(:not, [a], opts), do: "~#{atomize(a, opts)}"
  defp render_op(:neg, [a], opts), do: "-#{atomize(a, opts)}"

  defp render_op(:and, [a, b], opts), do: "#{atomize(a, opts)} /\\ #{atomize(b, opts)}"
  defp render_op(:or, [a, b], opts), do: "#{atomize(a, opts)} \\/ #{atomize(b, opts)}"

  defp render_op(op, [a, b], opts) when op in [:+, :-, :*] do
    symbol = Atom.to_string(op)
    "#{atomize(a, opts)} #{symbol} #{atomize(b, opts)}"
  end

  defp render_op(:in, [a, b], opts), do: "#{atomize(a, opts)} \\in #{atomize(b, opts)}"
  defp render_op(:notin, [a, b], opts), do: "#{atomize(a, opts)} \\notin #{atomize(b, opts)}"

  defp render_op(:subseteq, [a, b], opts),
    do: "#{atomize(a, opts)} \\subseteq #{atomize(b, opts)}"

  defp render_op(:union, [a, b], opts), do: "#{atomize(a, opts)} \\cup #{atomize(b, opts)}"
  defp render_op(:intersect, [a, b], opts), do: "#{atomize(a, opts)} \\cap #{atomize(b, opts)}"
  defp render_op(:setminus, [a, b], opts), do: "#{atomize(a, opts)} \\ #{atomize(b, opts)}"
  defp render_op(:concat, [a, b], opts), do: "#{atomize(a, opts)} \\o #{atomize(b, opts)}"
  defp render_op(:index, [s, i], opts), do: "#{render(s, opts)}[#{render(i, opts)}]"
  defp render_op(:div, [a, b], opts), do: "#{atomize(a, opts)} \\div #{atomize(b, opts)}"
  defp render_op(:mod, [a, b], opts), do: "#{atomize(a, opts)} \\mod #{atomize(b, opts)}"
  defp render_op(:pow, [a, b], opts), do: "#{atomize(a, opts)} ^ #{atomize(b, opts)}"

  @symbol %{:<= => "<=", :>= => ">=", :== => "=", :!= => "#"}

  defp render_op(op, [a, b], opts) when op in [:<, :>, :<=, :>=, :==, :!=] do
    symbol = if op == :<, do: "<", else: if(op == :>, do: ">", else: Map.fetch!(@symbol, op))
    "#{atomize(a, opts)} #{symbol} #{atomize(b, opts)}"
  end

  defp render_op(:if, [c, t, e], opts),
    do: "IF #{render(c, opts)} THEN #{render(t, opts)} ELSE #{render(e, opts)}"

  # Same-op chains (both/both, either/either, multi-line blocks) flatten so
  # the rendered formula has no redundant grouping. Only the chain's own op
  # splices: a `\/` inside a `/\` chain (or vice versa) stays a parenthesized
  # subterm, or `(a or b) and c` would render as `a /\ b /\ c`.
  defp flatten(op, {:op, op, args}), do: Enum.flat_map(args, &flatten(op, &1))
  defp flatten(_op, term), do: [term]

  # A chain item needs parens only when it binds no tighter than the chain:
  # the other junction (what `flatten` left behind) or an IF, which extends
  # as far right as it can. Comparisons and arithmetic bind tighter and read
  # cleaner bare (`x = 1 /\ y`).
  defp chain_item({:op, op, _} = term, opts) when op in [:parallel, :choice, :and, :or, :if],
    do: "(" <> render(term, opts) <> ")"

  defp chain_item(term, opts), do: render(term, opts)

  # `atomize` parenthesizes compound sub-terms. Conservative and simple: any
  # operator term gets parens when it sits as a subterm of another operator;
  # leaves (literals, variables, calls, sets, records) never do. TLA+'s `/\`
  # binds tighter than `\\/`, so explicit parens are always correct even when
  # occasionally redundant.
  defp atomize(term, opts) do
    case atomic?(term) do
      true -> render(term, opts)
      false -> "(" <> render(term, opts) <> ")"
    end
  end

  defp atomic?({:op, _, _}), do: false
  defp atomic?(_), do: true

  defp vars_subscript([one]), do: one
  defp vars_subscript(many), do: "<<#{Enum.join(Enum.sort(many), ", ")}>>"

  # ---------------------------------------------------------------------------
  # Translation
  #
  # One contiguous clause block: reserved words get their own clauses BEFORE
  # the generic identifier clause, and the fall-through error clause is last.
  # ---------------------------------------------------------------------------

  defp expr({:__block__, _, lines}, meta) when is_list(lines),
    do: lines |> List.wrap() |> Enum.map(&expr(&1, meta)) |> wrap_parallel()

  defp expr({:parallel, _, [do: lines]}, meta) when is_list(lines),
    do: lines |> List.wrap() |> Enum.map(&expr(&1, meta)) |> wrap_parallel()

  defp expr({:parallel, _, [do: line]}, meta), do: expr(line, meta)

  defp expr({:both, _, [a, b]}, meta), do: {:op, :parallel, [expr(a, meta), expr(b, meta)]}
  defp expr({:either, _, [a, b]}, meta), do: {:op, :choice, [expr(a, meta), expr(b, meta)]}

  defp expr(integer, _meta) when is_integer(integer), do: {:int, integer}
  defp expr(boolean, _meta) when is_boolean(boolean), do: {:bool, boolean}
  defp expr(binary, _meta) when is_binary(binary), do: {:str, binary}

  # `get(x)`: the next value of variable x.
  defp expr({:get, _, [{name, _, nil}]}, _meta) when is_atom(name) do
    validate_name!(name)
    {:prime, Atom.to_string(name)}
  end

  defp expr({:get, _, args} = ast, meta) when is_list(args) do
    raise Error,
      message: "`get/1` takes a single variable name, got: #{Macro.to_string(ast)}",
      meta: meta
  end

  # `unchanged(x)` / `unchanged([:x, :y])`.
  defp expr({:unchanged, _, args}, meta) when is_list(args) do
    {:unchanged, unchanged_names(args, meta)}
  end

  # `assign(x: v)`: changes one or more variables.
  defp expr({:assign, _, [kwargs]}, meta) when is_list(kwargs) and kwargs != [] do
    changes = assign_changes(kwargs, meta)
    reject_primed_in_value!(changes, meta)
    {:assign, changes}
  end

  defp expr({:assign, _, _} = ast, meta),
    do:
      raise(Error,
        message:
          "`assign/1` takes keyword arguments like `assign(x: 1)`, got: #{Macro.to_string(ast)}",
        meta: meta
      )

  # `set([...])`, `seq([...])`, `record(...)`.
  defp expr({:set, _, [items]}, meta) when is_list(items),
    do: {:enum, Enum.map(items, &expr(&1, meta))}

  defp expr({:seq, _, [items]}, meta) when is_list(items),
    do: {:seq, Enum.map(items, &expr(&1, meta))}

  defp expr({:record, _, [kwargs]}, meta) when is_list(kwargs),
    do: {:record, record_fields(kwargs, meta)}

  # Map literals %{a: 1} (atom keys only); tuple literals {a, b}; ranges a..b.
  defp expr({:%{}, _, pairs}, meta),
    do: {:record, record_fields(pairs, meta)}

  defp expr({:{}, _, items}, meta) when is_list(items),
    do: {:seq, Enum.map(items, &expr(&1, meta))}

  defp expr({:.., _, [a, b]}, meta), do: {:range, expr(a, meta), expr(b, meta)}

  defp expr({:not, _, [{:in, _, [a, b]}]}, meta),
    do: {:op, :notin, [expr(a, meta), expr(b, meta)]}

  # Same-op chains flatten so `a and b and c` renders as one /\ chain (the
  # emitter turns top-level chains vertical).
  defp expr({:and, _, [a, b]}, meta) when not is_nil(a) and not is_nil(b) do
    {:op, :parallel, [expr(a, meta), expr(b, meta)]}
  end

  defp expr({:or, _, [a, b]}, meta), do: {:op, :choice, [expr(a, meta), expr(b, meta)]}

  defp expr({op, _, [a, b]}, meta)
       when op in [:+, :-, :*, :/, :rem, :<, :>, :<=, :>=, :==, :!=, :in] do
    {:op, tla_op(op), [expr(a, meta), expr(b, meta)]}
  end

  defp expr({op, _, [a]}, meta) when op in [:-, :not] do
    {:op, if(op == :-, do: :neg, else: :not), [expr(a, meta)]}
  end

  defp expr({:if, _, [cond, kw]} = ast, meta) do
    unless Keyword.has_key?(kw, :else),
      do:
        raise(Error,
          message: "Every if needs an else (TLA+ expressions are total): #{Macro.to_string(ast)}",
          meta: meta
        )

    {:op, :if, [expr(cond, meta), expr(kw[:do], meta), expr(kw[:else], meta)]}
  end

  defp expr({:unless, _, [cond, kw]} = ast, meta) do
    unless Keyword.has_key?(kw, :else),
      do:
        raise(Error,
          message:
            "Every unless needs an else (TLA+ expressions are total): #{Macro.to_string(ast)}",
          meta: meta
        )

    {:op, :if, [{:op, :not, [expr(cond, meta)]}, expr(kw[:do], meta), expr(kw[:else], meta)]}
  end

  defp expr({tag, _, _} = ast, meta) when tag in [:cond, :case, :with, :for, :fn, :receive] do
    raise Error,
      message:
        "`#{tag}` is not part of the spec DSL: write nested if/else, or use the raw TLA+ escape hatch. Got: #{Macro.to_string(ast)}",
      meta: meta
  end

  # Temporal operators.
  defp expr({:eventually, _, [inner]}, meta), do: {:temporal, :eventually, [expr(inner, meta)]}
  defp expr({:always, _, [inner]}, meta), do: {:temporal, :always, [expr(inner, meta)]}

  defp expr({:leads_to, _, [a, b]}, meta),
    do: {:temporal, :leads_to, [expr(a, meta), expr(b, meta)]}

  defp expr({:enabled, _, [name]}, _meta) when is_atom(name),
    do: {:temporal, :enabled, [{:call, Atom.to_string(name), []}]}

  defp expr({:enabled, _, [name, params]}, meta) when is_atom(name) and is_list(params),
    do: {:temporal, :enabled, [{:call, Atom.to_string(name), Enum.map(params, &expr(&1, meta))}]}

  # Any other lowercase call: the supported-operator table.
  defp expr({name, _, args}, meta) when is_atom(name) and is_list(args) do
    case fun(name, Enum.map(args, &expr(&1, meta))) do
      :not_found ->
        raise Error,
          message:
            "Unknown or unsupported call in spec code: `#{name}/#{length(args)}`. " <>
              "See `Notary.DSL`'s documentation for the supported operators, or use the raw TLA+ escape hatch.",
          meta: meta

      term ->
        term
    end
  end

  # Snake_case identifiers: variables.
  defp expr({name, _, nil}, _meta) when is_atom(name) do
    validate_name!(name)
    {:var, Atom.to_string(name)}
  end

  # Keyword lists are records; plain lists and tuples are sequences.
  defp expr(list, meta) when is_list(list) do
    case Keyword.keyword?(list) do
      true -> {:record, record_fields(list, meta)}
      false -> {:seq, Enum.map(list, &expr(&1, meta))}
    end
  end

  defp expr({a, b}, meta), do: {:seq, [expr(a, meta), expr(b, meta)]}

  defp expr(ast, meta) do
    raise Error,
      message:
        "Cannot translate to TLA+: #{Macro.to_string(ast)}. " <>
          "See `Notary.DSL`'s documentation for the supported subset, or use the raw TLA+ escape hatch.",
      meta: meta
  end

  defp tla_op(:/), do: :div
  defp tla_op(:rem), do: :mod
  defp tla_op(op), do: op

  defp wrap_parallel([one]), do: one
  defp wrap_parallel(many), do: {:op, :parallel, many}

  defp unchanged_names([{name, _, nil}], _meta) when is_atom(name) do
    validate_name!(name)
    [Atom.to_string(name)]
  end

  defp unchanged_names([[_] = list], meta) when is_list(list) do
    Enum.map(list, fn
      {name, _, nil} when is_atom(name) ->
        validate_name!(name)
        Atom.to_string(name)

      other ->
        raise Error,
          message: "`unchanged/1` takes variable names, got: #{Macro.to_string(other)}",
          meta: meta
    end)
  end

  defp unchanged_names(_, meta),
    do:
      raise(Error, message: "`unchanged/1` takes one variable or a list of variables", meta: meta)

  defp assign_changes(kwargs, meta) do
    changes =
      Enum.reduce(kwargs, %{}, fn
        {name, v}, acc when is_atom(name) ->
          validate_name!(name)
          Map.put(acc, Atom.to_string(name), expr(v, meta))

        other, _ ->
          raise Error,
            message:
              "`assign/1` takes keyword arguments like `assign(count: get(count) + 1)`, got: #{Macro.to_string(other)}",
            meta: meta
      end)

    if changes == %{} do
      raise Error, message: "`assign/1` with no assignments", meta: meta
    end

    changes
  end

  defp record_fields(pairs, meta) do
    Enum.reduce(pairs, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, Atom.to_string(k), expr(v, meta))

      other, _ ->
        raise Error,
          message: "Record fields must be `key: value` pairs, got: #{Macro.to_string(other)}",
          meta: meta
    end)
  end

  # ---------------------------------------------------------------------------
  # The supported-operator table. Only standard TLA+ module operators, so the
  # generated module can `EXTENDS Naturals, Sequences, FiniteSets` and TLC
  # resolves everything. Arguments arrive already translated.
  # ---------------------------------------------------------------------------

  defp fun(:head, [s]), do: {:call, "Head", [s]}
  defp fun(:tail, [s]), do: {:call, "Tail", [s]}
  defp fun(:length, [s]), do: {:call, "Len", [s]}
  defp fun(:append, [s, x]), do: {:op, :concat, [s, {:seq, [x]}]}
  defp fun(:concat, [a, b]), do: {:op, :concat, [a, b]}
  defp fun(:at, [s, i]), do: {:op, :index, [s, i]}
  defp fun(:subseq, [s, a, b]), do: {:call, "SubSeq", [s, a, b]}

  defp fun(:member?, [x, s]), do: {:op, :in, [x, s]}
  defp fun(:set_union, [a, b]), do: {:op, :union, [a, b]}
  defp fun(:set_intersect, [a, b]), do: {:op, :intersect, [a, b]}
  defp fun(:set_diff, [a, b]), do: {:op, :setminus, [a, b]}
  defp fun(:cardinality, [s]), do: {:call, "Cardinality", [s]}

  defp fun(:domain, [r]), do: {:call, "DOMAIN", [r]}

  # No Naturals Min/Max; IF-expressions keep the module dependency-free.
  defp fun(:min, [a, b]), do: {:op, :if, [{:op, :<=, [a, b]}, a, b]}
  defp fun(:max, [a, b]), do: {:op, :if, [{:op, :>=, [a, b]}, a, b]}

  defp fun(_name, _args), do: :not_found

  # ---------------------------------------------------------------------------
  # Structural helpers
  # ---------------------------------------------------------------------------

  defp primed_vars({:prime, name}, acc), do: [name | acc]

  defp primed_vars({:assign, changes}, acc),
    do: Enum.reduce(changes, acc, fn {_k, v}, acc -> primed_vars(v, acc) end)

  defp primed_vars({:record, fields}, acc) when is_map(fields),
    do: Enum.reduce(Enum.sort(fields), acc, fn {_k, v}, acc -> primed_vars(v, acc) end)

  defp primed_vars({tag, inner}, acc) when tag in [:enum, :seq, :unchanged] and is_list(inner),
    do: Enum.reduce(inner, acc, &primed_vars/2)

  defp primed_vars({:range, a, b}, acc), do: acc |> primed_vars(a) |> primed_vars(b)

  # 3-tuples: op, call, temporal.
  defp primed_vars({_tag, _inner, args}, acc) when is_list(args),
    do: Enum.reduce(args, acc, &primed_vars/2)

  defp primed_vars(_leaf, acc), do: acc

  defp has_effect?({:assign, _}), do: true
  defp has_effect?({:unchanged, _}), do: true

  defp has_effect?({:op, op, args}) when op in [:parallel, :choice],
    do: Enum.any?(args, &has_effect?/1)

  defp has_effect?(_), do: false

  defp validate_name!(name) when is_atom(name) do
    unless Regex.match?(~r/^[a-z][a-zA-Z0-9_]*$/, Atom.to_string(name)) do
      raise Error,
        message:
          "Names in spec code must be lowercase identifiers, got #{inspect(name)}. " <>
            "(snake_case for variables; CamelCase names refer to actions.)"
    end
  end
end
