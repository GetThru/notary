defmodule Notary.Conformance.DSL do
  @moduledoc """
  Derives a mapping module's `actions/0` from its DSL spec module, so the
  spec's parameter domains are the single source of truth for what the runner
  generates:

      # specs source written with Notary.DSL:
      defmodule MyApp.Specs.Bank do
        use Notary.DSL, name: "Bank"
        ...
        action Deposit, param: 1..2 do ... end
      end

      # the conformance mapping:
      defmodule MyApp.Specs.BankMapping do
        use Notary.Conformance.DSL, from: MyApp.Specs.Bank
        import Notary.Conformance.DSL, only: [gen: 1]

        def init, do: MyApp.Bank.start_link()
        def action("Deposit", %{param: p}, ctx), do: ...
        def project(ctx), do: %{"balance" => ...}
      end

  What `use Notary.Conformance.DSL` emits:

    * `actions/0` derived from the DSL spec: one entry per *non-internal*
      spec action. A parameter domain `1..2` becomes `StreamData.integer(1..2)`,
      an enum `["a", "b"]` becomes `StreamData.member_of/1`; multiple params
      are combined with `StreamData.fixed_map`. Actions without parameters
      generate the empty params map.
    * Internal actions excluded: pass `internal: [...]` like
      `Notary.Conformance`; they are removed from the derived `actions/0`
      (and forwarded to the behaviour).

  `gen/1` is imported for *overriding* individual actions: define
  `def __gen__("Deposit"), do: <generator>` and the derived `actions/0` uses
  it instead of the domain-derived default.
  """

  defmacro __using__(opts) do
    spec_module = Keyword.fetch!(opts, :from)
    internal = Keyword.get(opts, :internal, [])
    observe = Keyword.get(opts, :observe)
    generation = Keyword.get(opts, :generation, :walk)
    spec_path = spec_path(spec_module)

    quote do
      use Notary.Conformance,
        spec: unquote(spec_path),
        observe: unquote(observe),
        internal: unquote(internal),
        generation: unquote(generation)

      import Notary.Conformance.DSL, only: [gen: 1]

      @doc false
      def __notary_dsl_spec__, do: unquote(spec_module)

      # The catch-all __gen__/1 is added in __before_compile__ (below), so a
      # user-defined `def __gen__("Name")` clause always precedes it.
      @before_compile {Notary.Conformance.DSL, :__before_compile__}

      @impl true
      def actions do
        Notary.Conformance.DSL.derived_actions(
          unquote(spec_module),
          __MODULE__,
          unquote(internal)
        )
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      # The fallback: no user clause matched, so derive from the parameter
      # domains. derived_actions/2 dispatches through __gen__/1 and resolves
      # the sentinel against the spec's domains.
      def __gen__(name), do: {:__notary_derive__, name}
    end
  end

  defp spec_path(spec_module) do
    # The spec module's DSL description knows its name; the path follows the
    # specs dir convention. Computed at expansion time for a compile-time
    # literal; module aliases are resolved by the compiler.
    case spec_module do
      {:__aliases__, _, _} ->
        quote do
          "specs/" <> unquote(spec_module).__notary_description__().name <> ".tla"
        end

      _ ->
        raise ArgumentError, "use Notary.Conformance.DSL expects from: SomeSpecModule"
    end
  end

  @doc """
  The derived `actions/0` map: every spec action except the declared
  internal ones. Generators are resolved through `mapping.__gen__/1` —
  mapping modules with no explicit `__gen__` clause hit the catch-all
  fallback (injected at __before_compile__), which returns the
  `{:__notary_derive__, name}` sentinel; here it is resolved against the
  spec's parameter domains.
  """
  @spec derived_actions(module(), module(), [String.t()]) :: %{String.t() => StreamData.t(map())}
  def derived_actions(spec_module, mapping, internal) do
    d = spec_module.__notary_description__()

    resolve = fn action ->
      case mapping.__gen__(action.name) do
        {:__notary_derive__, _} -> domain_generator(action)
        gen -> gen
      end
    end

    d.actions
    |> Enum.reject(&(&1.name in internal))
    |> Map.new(fn action -> {action.name, resolve.(action)} end)
  end

  @doc "The domain-derived generator for one action (params as a fixed map)."
  @spec derived_generator(module(), String.t()) :: StreamData.t(map())
  def derived_generator(spec_module, name) do
    d = spec_module.__notary_description__()

    case Enum.find(d.actions, &(&1.name == name)) do
      nil ->
        raise Notary.Error.new(
                :invalid_mapping,
                "Cannot derive a generator for #{name}: not an action of spec #{d.name} " <>
                  "(actions: #{d.actions |> Enum.map(& &1.name) |> Enum.join(", ")})."
              )

      # Always the domain-derived generator: the mapping's fall-back __gen__
      # delegate lands here (the mapping's own def would have won otherwise).
      action ->
        domain_generator(action)
    end
  end

  defp domain_generator(action) do
    case action.params do
      [] ->
        StreamData.constant(%{})

      params ->
        params
        |> Enum.map(&{safe_atom(&1.name), param_generator(&1.domain)})
        |> StreamData.fixed_map()
    end
  end

  defp safe_atom(name) do
    case Regex.match?(~r/^[a-z][a-zA-Z0-9_]*$/, name) do
      true ->
        String.to_atom(name)

      false ->
        raise Notary.Error.new(
                :invalid_mapping,
                "Parameter #{name} is not a valid Elixir atom key."
              )
    end
  end

  @doc "The StreamData generator for one parameter domain."
  @spec param_generator(Notary.DSL.Description.domain()) :: StreamData.t(map())
  def param_generator({:range, {:int, a}, {:int, b}}), do: StreamData.integer(a..b)

  def param_generator({:enum, items}) do
    # Values are simple literals; unwrap for member_of.
    case Enum.all?(items, &literal_term/1) do
      true ->
        items |> Enum.map(&literal_term/1) |> StreamData.member_of()

      false ->
        raise Notary.Error.new(
                :invalid_mapping,
                "Cannot derive a generator from a non-literal enum domain (use __gen__/1 to override)."
              )
    end
  end

  def param_generator({:boolean, nil}), do: StreamData.boolean()

  def param_generator(nil),
    do:
      raise(
        Notary.Error.new(
          :invalid_mapping,
          "Parameter has no domain; give it one (e.g. param: 1..2) or override with __gen__/1."
        )
      )

  def param_generator(other),
    do:
      raise(
        Notary.Error.new(
          :invalid_mapping,
          "Cannot derive a generator from domain #{inspect(other)}; override with __gen__/1."
        )
      )

  defp literal_term({:int, n}), do: n
  defp literal_term({:str, s}), do: s
  defp literal_term({:bool, b}), do: b
  defp literal_term(_), do: nil

  # --
  @doc "Marks a hand-written generator override inside a `Notary.Conformance.DSL` mapping."
  def gen(definition), do: definition
end
