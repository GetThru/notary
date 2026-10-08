defmodule Notary.DSL do
  @moduledoc ~S"""
  Write TLA+ specs in Elixir: the DSL for people who don't want to learn
  TLA+ (yet).

      defmodule MyApp.Specs.Checkout do
        use Notary.DSL, name: "Checkout"

        description "A three-step checkout: address, payment, done."

        variable step: ["address", "payment", "done"]
        variable address: boolean()

        initial step: "address", address: false

        action EnterAddress do
          guard step == "address"
          assign address: true
        end

        action Continue do
          guard step == "address" and address
          assign step: "payment"
        end

        action Pay do
          guard step == "payment" and address
          assign step: "done"
        end
      end

  Compiling that module emits `specs/Checkout.tla` and `specs/Checkout.cfg`
  (run `mix notary.compile`, or let any `mix notary.*` task sync first). The
  generated files carry a GENERATED marker: Notary overwrites them when the
  DSL changes, and refuses to touch a hand-written spec that collides.

  Everything downstream then works unchanged: `mix notary.check Checkout`,
  the lock file, `mix notary.graph`, conformance, diagnostics. Review the
  generated TLA+ the same way you'd review hand-written specs — it is the
  ladder back to real TLA+, not a cage.

  ## Surface

    * `description string` — the module comment at the top of the `.tla`.
    * `variable name: domain` — a `VARIABLES` entry and its `TypeOK` clause.
      Domains: `boolean()`, `["a", "b"]` (enum), `a..b` (range), `%{...}`/
      `[k: v, ...]` (a record with field domains). Uniqueness of enum values
      is your job; TLC treats a set as a set.
    * `constant Name: value` — a `CONSTANT` declaration and the model value
      in the `.cfg` in one step. Keep values small (see specs/AGENTS.md).
    * `initial name: value, ...` — the `Init` predicate; must cover every
      variable.
    * `action Name [param: domain, ...] [doc: string] do ... end` — a `Next`
      disjunct. The body is a list of statements:
        * `guard expr` — when the action is allowed (may repeat; conjunctive).
        * `doc string` — a comment on the action definition.
        * everything else is an effect and must contain `assign(...)`,
          `unchanged(...)`, `both(...)`, or `either(...)`.
    * `invariant Name, doc: ..., do: expr` — an `INVARIANT` in the `.cfg`.
      (`TypeOK` is generated from the variable domains.)
    * `property Name, doc: ..., do: temporal_expr` — a `PROPERTY`. Temporal
      operators: `always/1`, `eventually/1`, `leads_to/2`, `enabled/2`.
    * `fair Name` / `strong_fair Name` — weak/strong fairness (`WF_vars`/
      `SF_vars`) conjuncts added to `Spec`. Fair parameterized actions are
      emitted quantified: `fair Pay, params: ["amount"]` becomes
      `\A amount : WF_vars(Pay(amount))`; Notary's fairness scan still finds
      `Pay`.
    * `raw tla_string` — raw TLA+ definitions spliced in before `Next`, for
      anything the surface doesn't cover (quantifiers, set comprehensions
     , sequences). The escape hatch; use it sparingly.

  `assign(x: e)` sets `x' = e`; `get(x)` refers to `x'`. Guards may not use
  `get/1`; a body with no `assign/1` fails to compile. The expression subset
  and its TLA+ rendering are documented in `Notary.DSL.Expr`.

  ## Generating StreamData

  Action parameter domains double as generators: pair the DSL module with a
  mapping via `use Notary.Conformance.DSL, from: MyApp.Specs.Checkout` and
  `actions/0` is derived (`1..2` → `StreamData.integer(1..2)`, enums →
  `member_of/1`); see that module. One source of truth for what the spec
  says and what the runner drives.

  ## Where DSL modules live

  Anywhere your `:test` `elixirc_paths` compiles. `mix notary.new Name
  --dsl` scaffolds `test/support/specs/name.ex`; the generated `.tla`/`.cfg`
  land in `specs/` like any other spec.
  """

  alias Notary.DSL.{Description, Error, Expr}

  # ---------------------------------------------------------------------------
  # use Notary.DSL
  # ---------------------------------------------------------------------------

  defmacro __using__(opts) do
    name = Keyword.get(opts, :name)

    quote do
      import Notary.DSL

      Module.register_attribute(__MODULE__, :notary_dsl, accumulate: true)
      Module.put_attribute(__MODULE__, :notary_dsl_name, unquote(name))

      @before_compile {Notary.DSL, :__before_compile__}
    end
  end

  # ---------------------------------------------------------------------------
  # Surface macros. Each validates and translates its piece at expansion time
  # (with __CALLER__'s file/line for errors) and pushes onto :notary_dsl.
  # ---------------------------------------------------------------------------

  @doc "The comment block at the top of the generated module."
  defmacro description(text) when is_binary(text) do
    push({:description, text}, __CALLER__)
  end

  @doc "Declares a variable and its domain (`TypeOK`)."
  defmacro variable(domain_kw) when is_list(domain_kw) do
    {name, domain_ast} = single_kw!(domain_kw, "variable")
    domain = translate_domain!(domain_ast, meta(__CALLER__))
    push({:variable, Atom.to_string(name), domain}, __CALLER__)
  end

  @doc "Declares a CONSTANT and picks its model value."
  defmacro constant(kw) when is_list(kw) do
    {name, value} = single_kw!(kw, "constant")
    push({:constant, Atom.to_string(name), value}, __CALLER__)
  end

  @doc "The Init predicate; every variable must get a starting value."
  defmacro initial(kw) when is_list(kw) do
    entries =
      Enum.map(kw, fn {name, value_ast} when is_atom(name) ->
        {Atom.to_string(name), Expr.value(value_ast, meta(__CALLER__))}
      end)

    push({:initial, entries}, __CALLER__)
  end

  @doc """
  Declares an action: a disjunct of `Next`.

      action Pay do
        guard step == "payment" and address
        assign step: "done"
      end

  Options: `doc: "..."`, `explicit_unchanged: true`, and parameter domains
  as keyword pairs (`param: 1..2` declares a parameterized TLA+ action
  `Deposit(param)`; `Next` quantifies it: `\\E param \\in 1..2 : Deposit(param)`).
  """
  # `action Greet do ... end` binds (name, [do: ...]); with opts
  # (`action Deposit, param: 1..2 do ... end`) it binds (name, opts, [do: ...]).
  defmacro action(name_ast, kw) do
    action_declare(name_ast, List.wrap(kw), __CALLER__)
  end

  defmacro action(name_ast, kw, do: body) when is_list(kw) do
    action_declare(name_ast, kw ++ [do: body], __CALLER__)
  end

  @doc "Declares an invariant (added to the .cfg's INVARIANT list)."
  defmacro invariant(name, kw) do
    invariant_property(:invariant, name, List.wrap(kw), __CALLER__)
  end

  defmacro invariant(name, kw, do: expr_value) when is_list(kw) do
    invariant_property(:invariant, name, kw ++ [do: expr_value], __CALLER__)
  end

  @doc "Declares a temporal property (added to the .cfg's PROPERTY list)."
  defmacro property(name, kw) do
    invariant_property(:property, name, List.wrap(kw), __CALLER__)
  end

  defmacro property(name, kw, do: expr_value) when is_list(kw) do
    invariant_property(:property, name, kw ++ [do: expr_value], __CALLER__)
  end

  # `invariant TypeOK do ... end`, `invariant TypeOK, doc: "..." do ... end`,
  # and `invariant TypeOk, do: expr` all bind the keyword list (do included)
  # as the second argument. CamelCase names arrive as aliases.
  defp invariant_property(kind, {name, _, nil}, kw, caller) when is_atom(name),
    do: invariant_property(kind, {:__aliases__, [], [name]}, kw, caller)

  defp invariant_property(kind, {:__aliases__, _, [name]}, kw, caller)
       when is_atom(name) do
    meta = meta(caller)
    doc = kw[:doc]
    expr_ast = Keyword.fetch!(kw, :do)
    expr_t = (kind == :invariant && Expr.guard(expr_ast, meta)) || Expr.formula(expr_ast, meta)

    push({kind, Atom.to_string(name), expr_t, doc, meta[:line]}, meta)
  end

  defp invariant_property(_kind, other, _kw, caller) do
    raise Error,
      message:
        "#{Macro.to_string(other)}: invariant/property names must be CamelCase identifiers",
      meta: meta(caller)
  end

  # -- action helpers ----------------------------------------------------------

  defp action_declare(name_ast, kw, caller) do
    meta = meta(caller)

    doc = Keyword.get(kw, :doc)
    explicit = Keyword.get(kw, :explicit_unchanged, false)
    body = Keyword.fetch!(kw, :do)

    params_kw =
      kw
      |> Keyword.delete(:do)
      |> Keyword.delete(:doc)
      |> Keyword.delete(:explicit_unchanged)

    {params, guards, effects} = action_body(body, params_kw, meta)

    action_push(name_ast, params, guards, effects, doc, explicit, meta)
  end

  defp action_push({:__aliases__, _, [name]}, params, guards, effects, doc, explicit, meta)
       when is_atom(name),
       do:
         push(
           {:action, Atom.to_string(name), params, guards, effects, doc, explicit, meta[:line]},
           meta
         )

  defp action_push({name, _, nil}, params, guards, effects, doc, explicit, meta)
       when is_atom(name),
       do:
         push(
           {:action, Atom.to_string(name), params, guards, effects, doc, explicit, meta[:line]},
           meta
         )

  defp action_push(other, _params, _guards, _effects, _doc, _explicit, meta) do
    raise Error,
      message: "action names must be CamelCase identifiers, got: #{Macro.to_string(other)}",
      meta: meta
  end

  # The action body: statements are `guard expr` or effects. (Docs go in the
  # action's `doc:` option, not a body statement: `do doc "..." ... end`
  # would parse `doc:` as a keyword of the macro call, not a statement.)
  defp action_body(body, params_kw, meta) do
    params =
      Enum.map(params_kw, fn {name, domain_ast} ->
        %{name: Atom.to_string(name), domain: translate_domain!(domain_ast, meta)}
      end)

    {params, guards, effects} =
      Enum.reduce(body_list(body), {params, [], []}, fn statement, acc ->
        reduce_statement(statement, acc, meta)
      end)

    {params, Enum.reverse(guards), Enum.reverse(effects)}
  end

  defp body_list({:__block__, _, statements}) when is_list(statements), do: statements
  defp body_list(single), do: List.wrap(single)

  defp reduce_statement({:guard, _, [expr_value]}, {params, guards, effects}, meta) do
    {params, [Expr.guard(expr_value, meta) | guards], effects}
  end

  defp reduce_statement({kw, _, _}, _acc, meta) when kw in [:doc] do
    raise Error,
      message: "doc is an action option, not a statement: `action Name, doc: \"...\" do ... end`",
      meta: meta
  end

  defp reduce_statement(effect, {params, guards, effects}, meta),
    do: {params, guards, [Expr.effect(effect, meta) | effects]}

  @doc "Weak fairness (`WF_vars`) for one or more actions."
  defmacro fair(names) do
    fairness(:weak, List.wrap(names), __CALLER__)
  end

  @doc "Strong fairness (`SF_vars`) for one or more actions."
  defmacro strong_fair(names) do
    fairness(:strong, List.wrap(names), __CALLER__)
  end

  @doc "Raw TLA+ definitions spliced in before `Next`. The escape hatch."
  defmacro raw(text) when is_binary(text) do
    push({:raw, String.trim(text)}, __CALLER__)
  end

  # -- macro helpers -----------------------------------------------------------

  defp push(entry, caller) do
    quote do
      Module.put_attribute(__MODULE__, :notary_dsl, unquote(Macro.escape(entry)))
      :ok
    end
    |> tap(fn _ -> validate_line!(entry, caller) end)
  end

  defp validate_line!({:action, _, _, _, _, _, _, line}, _caller) when line == nil, do: :ok
  defp validate_line!(_, _), do: :ok

  defp meta(caller), do: [file: caller.file, line: caller.line]

  defp single_kw!([{name, value}], _what) when is_atom(name), do: {name, value}

  defp single_kw!(kw, what),
    do: raise(Error, message: "#{what} takes a single `name: value`, got: #{Macro.to_string(kw)}")

  # Domains: boolean(), enum lists, ranges, records.
  defp translate_domain!({:boolean, _, []}, _meta), do: {:boolean, nil}

  defp translate_domain!({:.., _, [a, b]}, meta),
    do: {:range, Expr.value(a, meta), Expr.value(b, meta)}

  defp translate_domain!(list, meta) when is_list(list) do
    cond do
      Keyword.keyword?(list) ->
        {:record, Map.new(list, fn {k, v} -> {Atom.to_string(k), translate_domain!(v, meta)} end)}

      true ->
        {:enum, Enum.map(list, &Expr.value(&1, meta))}
    end
  end

  defp translate_domain!({:%{}, _, pairs}, meta),
    do:
      {:record, Map.new(pairs, fn {k, v} -> {Atom.to_string(k), translate_domain!(v, meta)} end)}

  defp translate_domain!(domain, meta),
    do:
      raise(Error,
        message:
          "Variable domains must be boolean(), an enum list like [\"a\", \"b\"], a range like 0..9, " <>
            "or a record %{field: domain}; got: #{Macro.to_string(domain)}",
        meta: meta
      )

  defp fairness(strength, names, caller) do
    entries =
      for name <- names do
        action_name =
          case name do
            {action, _, nil} when is_atom(action) ->
              action

            {:__aliases__, _, [action]} when is_atom(action) ->
              action

            other ->
              raise(Error,
                message: "fair/strong_fair take action names, got: #{Macro.to_string(other)}",
                meta: meta(caller)
              )
          end

        {:fair, strength, Atom.to_string(action_name), meta(caller)}
      end

    Enum.map(entries, fn {kind, strength, name, meta} ->
      push({kind, strength, name}, meta)
    end)
    |> then(fn pushes ->
      quote do
        unquote_splicing(pushes)
        :ok
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # __before_compile__: assemble + validate the description, define accessors.
  # ---------------------------------------------------------------------------

  defmacro __before_compile__(env) do
    entries = Module.get_attribute(env.module, :notary_dsl) || []
    name = spec_name(env, Module.get_attribute(env.module, :notary_dsl_name))

    description = build(name, entries, env)

    Module.put_attribute(env.module, :notary_dsl_description, description)

    quote do
      @doc false
      def __notary_description__, do: unquote(Macro.escape(description))
    end
  end

  defp spec_name(_env, explicit) when is_binary(explicit), do: explicit

  defp spec_name(env, nil) do
    env.module
    |> Module.split()
    |> List.last()
    |> String.trim_leading(":")
    |> camel()
  end

  defp camel(segment) do
    segment
    |> Macro.underscore()
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  # Assemble entries (in declaration order, but grouped by kind as the struct
  # wants) and run structural validation.
  defp build(name, entries, env) do
    description =
      %Description{name: name, source_module: inspect(env.module)}
      |> accumulate(entries)

    validate(description, env)
    description
  end

  defp accumulate(%Description{} = d, entries) do
    Enum.reduce(entries, d, fn
      {:description, text}, %Description{} = d ->
        %Description{d | doc: text}

      {:variable, name, domain}, %Description{} = d ->
        %Description{d | variables: d.variables ++ [%{name: name, type: domain}]}

      {:constant, name, value}, %Description{} = d ->
        %Description{d | constants: d.constants ++ [%{name: name, value: value}]}

      {:initial, entries}, %Description{} = d ->
        %Description{d | initial: Map.merge(d.initial, Map.new(entries))}

      {:action, name, params, guards, effects, doc, explicit, line}, %Description{} = d ->
        %Description{
          d
          | actions:
              d.actions ++
                [
                  %{
                    name: name,
                    params: params,
                    guards: guards,
                    effects: effects,
                    doc: doc,
                    explicit_unchanged: explicit,
                    line: line
                  }
                ]
        }

      {:invariant, name, expr_value, doc, line}, %Description{} = d ->
        %Description{
          d
          | invariants: d.invariants ++ [%{name: name, expr: expr_value, doc: doc, line: line}]
        }

      {:property, name, expr_value, doc, line}, %Description{} = d ->
        %Description{
          d
          | properties: d.properties ++ [%{name: name, expr: expr_value, doc: doc, line: line}]
        }

      {:fair, strength, name}, %Description{} = d ->
        %Description{d | fairness: d.fairness ++ [%{name: name, strength: strength}]}

      {:raw, text}, %Description{} = d ->
        %Description{d | raw_defs: d.raw_defs ++ [text]}
    end)
  end

  # -- validation --------------------------------------------------------------

  defp validate(%Description{} = d, env) do
    problems =
      [
        validate_variables(d),
        validate_constants(d),
        validate_actions(d),
        validate_initial(d),
        validate_fairness(d),
        validate_names(d),
        validate_exprs(d)
      ]
      |> Enum.concat()

    case problems do
      [] ->
        :ok

      problems ->
        raise Error,
          message:
            "Spec #{d.name} (from #{inspect(env.module)}) is invalid:\n  " <>
              Enum.join(problems, "\n  "),
          file: env.file
    end
  end

  defp validate_variables(d) do
    names = Enum.map(d.variables, & &1.name)

    dup_problems = duplicates(names) |> Enum.map(&"variable #{&1} declared more than once.")

    no_vars =
      if d.variables == [],
        do: ["no variables: even a one-variable spec needs state to check."],
        else: []

    no_vars ++ dup_problems
  end

  defp validate_constants(d),
    do:
      duplicates(Enum.map(d.constants, & &1.name))
      |> Enum.map(&"constant #{&1} declared more than once.")

  defp validate_actions(d) do
    names = Enum.map(d.actions, & &1.name)
    var_names = MapSet.new(Enum.map(d.variables, & &1.name))

    param_problems =
      for a <- d.actions,
          p <- a.params,
          p.name in names do
        "action #{a.name}'s parameter #{p.name} shadows a spec action name."
      end

    var_shadowing =
      for a <- d.actions,
          p <- a.params,
          MapSet.member?(var_names, p.name) do
        "action #{a.name}'s parameter #{p.name} shadows a spec variable."
      end

    no_actions =
      if d.actions == [],
        do: ["no actions: a spec needs at least one action (what the code can do)."],
        else: []

    (no_actions ++
       Enum.map(duplicates(names), &"action #{&1} declared more than once.") ++
       param_problems ++ var_shadowing)
    |> Enum.filter(&is_binary/1)
  end

  defp validate_initial(d) do
    var_names = Enum.map(d.variables, & &1.name)
    missing = Enum.reject(var_names, &Map.has_key?(d.initial, &1))
    extra = Map.keys(d.initial) -- var_names

    Enum.filter(
      [
        missing != [] && "initial/1 is missing starting values for: #{Enum.join(missing, ", ")}.",
        extra != [] && "initial/1 sets names that are not variables: #{Enum.join(extra, ", ")}."
      ],
      &is_binary/1
    )
  end

  defp validate_fairness(d) do
    action_names = MapSet.new(Enum.map(d.actions, & &1.name))

    for f <- d.fairness, not MapSet.member?(action_names, f.name) do
      "#{f.strength} fair action #{f.name} is not an action of this spec."
    end
  end

  defp validate_names(d) do
    reserved = ["Init", "Next", "Spec", "TypeOK", "vars"]

    declared =
      Enum.concat([
        Enum.map(d.variables, & &1.name),
        Enum.map(d.constants, & &1.name),
        Enum.map(d.actions, & &1.name),
        Enum.map(d.invariants, & &1.name),
        Enum.map(d.properties, & &1.name)
      ])

    for name <- declared, name in reserved do
      "`#{name}` is reserved (Notary generates it); pick another name."
    end
    |> Kernel.++(
      for name <- declared, not Regex.match?(~r/^[A-Za-z][A-Za-z0-9_]*$/, name) do
        "name #{inspect(name)} is not a valid TLA+ identifier."
      end
    )
    |> Kernel.++(
      duplicates(Enum.map(d.invariants, & &1.name))
      |> Enum.map(&"invariant #{&1} declared more than once.")
    )
    |> Kernel.++(
      duplicates(Enum.map(d.properties, & &1.name))
      |> Enum.map(&"property #{&1} declared more than once.")
    )
  end

  # Variables referenced in exprs must be declared (an undeclared name renders
  # as a TLA+ CONSTANT, which fails TLC later with a confusing error).
  defp validate_exprs(d) do
    action_param_names =
      Enum.flat_map(d.actions, fn a -> Enum.map(a.params, & &1.name) end)

    declared =
      MapSet.new(
        Enum.map(d.variables, & &1.name) ++
          Enum.map(d.actions, & &1.name) ++ action_param_names
      )

    referenced =
      Enum.flat_map(d.initial, fn {_k, v} -> expr_vars(v) end) ++
        Enum.flat_map(d.actions, fn a -> Enum.flat_map(a.guards ++ a.effects, &expr_vars/1) end) ++
        Enum.flat_map(d.invariants, fn i -> expr_vars(i.expr) end) ++
        Enum.flat_map(d.properties, fn p -> expr_vars(p.expr) end)

    constant_names = Enum.map(d.constants, & &1.name)

    undeclared =
      referenced
      |> Enum.uniq()
      |> Enum.reject(&(MapSet.member?(declared, &1) or &1 in constant_names))

    case undeclared do
      [] ->
        []

      names ->
        [
          "Undeclared names in expressions (neither variables nor constants): #{Enum.join(names, ", ")}."
        ]
    end
  end

  defp expr_vars({:var, name}), do: [name]
  defp expr_vars({:prime, name}), do: [name]

  defp expr_vars({:call, name, args})
       when name not in ["Head", "Tail", "Len", "SubSeq", "Cardinality", "DOMAIN", "BOOLEAN"],
       do: Enum.flat_map(args, &expr_vars/1) ++ [name]

  defp expr_vars({:call, _name, args}), do: Enum.flat_map(args, &expr_vars/1)

  defp expr_vars(term) do
    children =
      case term do
        {:op, _, args} -> args
        {:enum, items} -> items
        {:seq, items} -> items
        {:record, fields} when is_map(fields) -> Map.values(fields)
        {:assign, changes} -> Map.values(changes)
        {:temporal, _, args} -> args
        {:range, a, b} -> [a, b]
        _ -> []
      end

    Enum.flat_map(children, &expr_vars/1)
  end

  defp duplicates(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_k, n} -> n > 1 end)
    |> Enum.map(&elem(&1, 0))
  end
end
