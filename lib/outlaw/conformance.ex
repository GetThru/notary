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

    quote do
      @behaviour Outlaw.Conformance
      import Outlaw.Value, only: [model: 1, set: 1]

      @doc false
      def __outlaw__,
        do: %{spec_path: unquote(spec), observe: unquote(observe), discover: unquote(discover)}
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
    unknown_actions = Enum.reject(actions, &MapSet.member?(graph.actions, &1))
    unknown_vars = Enum.reject(observed_vars(module, graph), &(&1 in graph.variables))

    problems =
      [
        actions == [] && "actions/0 returned no actions.",
        unknown_actions != [] &&
          "actions/0 names actions that never occur in the spec's state graph: #{Enum.join(unknown_actions, ", ")}. " <>
            "Known actions: #{graph.actions |> Enum.sort() |> Enum.join(", ")}. (An action that is never enabled under the .cfg constants does not appear.)",
        unknown_vars != [] &&
          "observe: lists variables the spec does not have: #{Enum.join(unknown_vars, ", ")}. Spec variables: #{Enum.join(graph.variables, ", ")}."
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

  @spec discover_mappings(atom()) :: %{String.t() => module()}
  def discover_mappings(app) do
    Application.load(app)

    for module <- Application.spec(app, :modules) || [],
        Code.ensure_loaded?(module),
        function_exported?(module, :__outlaw__, 0),
        module.__outlaw__().discover,
        into: %{} do
      {spec(module).name, module}
    end
  end
end
