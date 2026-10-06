defmodule Outlaw.Conformance do
  @moduledoc """
  The contract between a TLA+ spec and its Elixir implementation.

      defmodule MyApp.Specs.Bank do
        use Outlaw.Conformance, spec: "specs/Bank.tla", observe: ["balance"]

        def init, do: MyApp.Bank.start_link()
        def actions, do: %{"Deposit" => StreamData.fixed_map(%{a: StreamData.integer(1..2)})}
        def action("Deposit", %{a: a}, pid), do: ...  # {:ok, pid} | {:rejected, reason, pid}
        def project(pid), do: %{"balance" => MyApp.Bank.balance(pid)}
      end

  Options:
    * `:spec` (required): path to the `.tla` file, relative to the project root.
    * `:observe`: spec variables `project/1` returns (default: all).
    * `:discover`: set `false` to hide the module from `mix outlaw.test` discovery.
    * `:internal`: names of spec actions the implementation performs on its own
      (a GenServer reacting to a message, a watchdog, ...), never on request.
      The runner never generates these as steps; instead it treats the
      implementation as free to take any number of them at any time, and
      *settles* at the end of each run — waiting (up to `Outlaw.Config`'s
      `settle_timeout`, default 1 s) until the implementation reaches a
      candidate state where no fair internal action is enabled (self-loops
      ignored). Fairness comes from the spec itself, not every declared
      internal action: only the ones named in a `WF_<sub>(Name)` or
      `SF_<sub>(Name)` occurrence in the spec's text (`Outlaw.Spec.fair_actions/1`)
      must eventually happen; a declared internal action the spec never marks
      fair is never required to fire. Each name must be an action in the
      spec's state graph and must not also appear as a key of `actions/0`
      (validated, `:invalid_mapping`). See the Outlaw design spec §4.3/§5.
      With fair internal actions declared, the generator may also place
      `:settle` points mid-run, where the runner settles the same way before
      continuing.
    * `:generation`: `:walk` (default) generates sequences by walking the
      spec's state graph (`Outlaw.Conformance.Walk`, design spec §5.1);
      `:uniform` keeps the Phase 1 generator (uniform picks from `actions/0`,
      no `:settle` points) — measured about 1.4-1.7x faster per run on
      Outlaw's own `specs/TLCRunner.tla`, useful as a baseline. Anything else
      fails validation (`:invalid_mapping`).

  `project/1` must return values in the `Outlaw.Value` representation; `model/1`
  and `set/1` are imported. Prefer unnamed processes (or stop them in
  `teardown/1`): every run calls `init/0` again.
  """

  alias Outlaw.{Error, Spec, StateGraph}

  @type ctx :: term()

  @callback init() :: {:ok, ctx()}
  @callback actions() :: %{String.t() => StreamData.t(map())}
  @callback action(String.t(), map(), ctx()) :: {:ok, ctx()} | {:rejected, term(), ctx()}
  @callback project(ctx()) :: %{String.t() => Outlaw.Value.t()}
  @callback teardown(ctx()) :: any()
  @optional_callbacks teardown: 1

  defmacro __using__(opts) do
    spec = Keyword.fetch!(opts, :spec)
    observe = Keyword.get(opts, :observe)
    discover = Keyword.get(opts, :discover, true)
    internal = Keyword.get(opts, :internal, [])
    generation = Keyword.get(opts, :generation, :walk)

    quote do
      @behaviour Outlaw.Conformance
      import Outlaw.Value, only: [model: 1, set: 1]

      @doc false
      def __outlaw__,
        do: %{
          spec_path: unquote(spec),
          observe: unquote(observe),
          discover: unquote(discover),
          internal: unquote(internal),
          generation: unquote(generation)
        }
    end
  end

  @spec spec(module()) :: Spec.t()
  def spec(module), do: Spec.from_path(module.__outlaw__().spec_path)

  @spec observed_vars(module(), StateGraph.t()) :: [String.t()]
  def observed_vars(module, %StateGraph{} = graph),
    do: module.__outlaw__().observe || graph.variables

  @spec validate(module(), StateGraph.t()) :: :ok | {:error, Error.t()}
  def validate(module, %StateGraph{} = graph) do
    actions = module.actions() |> Map.keys() |> Enum.sort()
    internal = Map.get(module.__outlaw__(), :internal, [])
    unknown_actions = Enum.reject(actions, &MapSet.member?(graph.actions, &1))
    unknown_vars = Enum.reject(observed_vars(module, graph), &(&1 in graph.variables))
    unknown_internal = Enum.reject(internal, &MapSet.member?(graph.actions, &1))
    internal_in_actions = Enum.filter(internal, &(&1 in actions))
    generation = Map.get(module.__outlaw__(), :generation, :walk)

    problems =
      [
        actions == [] && "actions/0 returned no actions.",
        unknown_actions != [] &&
          "actions/0 names actions that never occur in the spec's state graph: #{Enum.join(unknown_actions, ", ")}. " <>
            "Known actions: #{graph.actions |> Enum.sort() |> Enum.join(", ")}. (An action that is never enabled under the .cfg constants does not appear.)",
        unknown_vars != [] &&
          "observe: lists variables the spec does not have: #{Enum.join(unknown_vars, ", ")}. Spec variables: #{Enum.join(graph.variables, ", ")}.",
        unknown_internal != [] &&
          "internal: lists actions that never occur in the spec's state graph: #{Enum.join(unknown_internal, ", ")}. " <>
            "Known actions: #{graph.actions |> Enum.sort() |> Enum.join(", ")}.",
        internal_in_actions != [] &&
          "internal: #{Enum.join(internal_in_actions, ", ")} must not also be a key of actions/0 (internal actions are never driven by the runner; see Outlaw.Conformance's :internal option).",
        generation not in [:walk, :uniform] &&
          "generation: must be :walk (the default, spec-guided) or :uniform, got: #{inspect(generation)}."
      ]
      |> Enum.filter(&is_binary/1)

    case problems do
      [] ->
        :ok

      _ ->
        {:error,
         Error.new(
           :invalid_mapping,
           "Invalid mapping #{inspect(module)}:\n  " <> Enum.join(problems, "\n  ")
         )}
    end
  end

  @spec check(module(), StateGraph.t(), keyword()) ::
          {:ok,
           %{
             runs: non_neg_integer(),
             seed: integer(),
             coverage: Outlaw.Conformance.Coverage.summary()
           }}
          | {:error, Outlaw.Conformance.Failure.t()}
          | {:error, Error.t()}
  def check(module, %StateGraph{} = graph, opts \\ []) do
    with :ok <- validate(module, graph),
         {:ok, fair} <- Spec.fair_actions(spec(module)) do
      Outlaw.Conformance.Runner.check(
        module,
        graph,
        observed_vars(module, graph),
        Keyword.put(opts, :fair, fair)
      )
    end
  end

  @doc "Internal actions the mapping declares (sorted)."
  @spec internal_actions(module()) :: [String.t()]
  def internal_actions(module), do: module.__outlaw__() |> Map.get(:internal, []) |> Enum.sort()

  @doc """
  The declared internal actions that the spec's text also marks fair (sorted).

  Raises `Outlaw.Error` when the spec file named by the mapping's `spec:`
  option can't be read (a typo'd path surfaces here, with the file named).
  """
  @spec fair_internal_actions(module()) :: [String.t()] | no_return()
  def fair_internal_actions(module) do
    with {:ok, fair} <- Spec.fair_actions(spec(module)) do
      Enum.filter(internal_actions(module), &MapSet.member?(fair, &1))
    else
      {:error, error} -> raise error
    end
  end

  @doc """
  ExUnit-friendly conformance check for plain `mix test`:

      test "Bank conforms", do: Outlaw.Conformance.assert_conforms(MyApp.Specs.Bank)
  """
  @spec assert_conforms(module(), keyword()) :: :ok
  def assert_conforms(module, opts \\ []) do
    spec = spec(module)
    result = Outlaw.Verify.test_spec(spec, %{spec.name => module}, opts)

    if result.status == :pass do
      :ok
    else
      report = Outlaw.Report.format(%{status: :fail, lock: nil, specs: [result]})
      raise Error.new(:conformance_failed, report)
    end
  end

  @spec discover_mappings(atom()) :: %{String.t() => module()}
  def discover_mappings(app) do
    case Application.load(app) do
      :ok ->
        :ok

      {:error, {:already_loaded, ^app}} ->
        :ok

      {:error, reason} ->
        raise Error.new(
                :invalid_mapping,
                "Could not load app #{inspect(app)}: #{inspect(reason)}"
              )
    end

    from_modules(
      for module <- Application.spec(app, :modules) || [],
          Code.ensure_loaded?(module),
          function_exported?(module, :__outlaw__, 0),
          module.__outlaw__().discover,
          do: module
    )
  end

  @doc """
  Builds the spec-name → mapping-module map from already-filtered mapping
  modules, raising a single actionable error when two of them map the same
  spec (a stale `*_spec.ex` left next to a new one, or a copy): keyed on spec
  name, the result would otherwise silently keep whichever module comes later
  in `Application.spec`'s (unspecified) order and run the wrong mapping.
  """
  @spec from_modules([module()]) :: %{String.t() => module()}
  def from_modules(modules) do
    by_name =
      for module <- modules, reduce: %{} do
        acc -> Map.update(acc, spec(module).name, [module], &[module | &1])
      end

    duplicates =
      for {name, mods} <- by_name,
          mods = Enum.uniq(mods),
          length(mods) > 1 do
        {name, Enum.sort(mods)}
      end
      |> Enum.sort()

    case duplicates do
      [] ->
        Map.new(by_name, fn {name, [module]} -> {name, module} end)

      _ ->
        problems =
          duplicates
          |> Enum.map_join("\n", fn {name, mods} ->
            "  #{name}: #{Enum.map_join(mods, ", ", &inspect/1)}"
          end)

        raise Error.new(
                :invalid_mapping,
                "Multiple mapping modules map the same spec; keep only one per spec:\n#{problems}"
              )
    end
  end
end
