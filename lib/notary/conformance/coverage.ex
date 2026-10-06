defmodule Notary.Conformance.Coverage do
  @moduledoc """
  Pure coverage accumulation for a passing conformance check (Notary design
  spec §5.2): which actions, observed-state projections and transitions its
  runs reached, against the graph's totals. No processes, no I/O — `new/4`
  computes the totals once from the graph, and `add_run/2` folds one run's
  `[Step.t()]` into the running totals. `Notary.Conformance.Runner.check/4`
  accumulates across every run inside a single `StreamData.check_all` pass
  (never during post-shrink minimization replays) and calls `summary/1` only
  if the check passes.

  Totals:
    * **actions** — graph action labels that are either an external key of
      `actions/0` or a declared internal action.
    * **observed states** — distinct projections (on the observed variables)
      of all graph states.
    * **observed transitions** — distinct `(projection before, action,
      projection after)` triples of the graph's external-action edges.

  Reached:
    * **external action** — some step accepted it (`outcome: :ok`).
    * **internal action** — see `add_run/2`'s internal-action rule below.
    * **observed state** — some step's `projection` (any step: accepted,
      rejected, settle or the initial step).
    * **transition** — consecutive `(prev step's projection, action, this
      step's projection)` for accepted, non-settle steps.

  `unreached` lists in `summary/1` are capped at 20 entries, sorted (Erlang
  term order — numbers and strings sort as expected; this is just for a
  stable, deterministic report, not a domain-specific "simplest first").
  """

  alias Notary.StateGraph
  alias Notary.Conformance.{Step, Walk}

  @enforce_keys [:graph, :observe, :internal]
  defstruct [
    :graph,
    :observe,
    :internal,
    actions_total: MapSet.new(),
    states_total: MapSet.new(),
    transitions_total: MapSet.new(),
    actions_reached: MapSet.new(),
    states_reached: MapSet.new(),
    transitions_reached: MapSet.new()
  ]

  @type projection :: map()
  @type transition :: {projection(), String.t(), projection()}
  @type t :: %__MODULE__{
          graph: StateGraph.t(),
          observe: [String.t()],
          internal: [String.t()],
          actions_total: MapSet.t(String.t()),
          states_total: MapSet.t(projection()),
          transitions_total: MapSet.t(transition()),
          actions_reached: MapSet.t(String.t()),
          states_reached: MapSet.t(projection()),
          transitions_reached: MapSet.t(transition())
        }
  @type section :: %{reached: non_neg_integer(), total: non_neg_integer(), unreached: list()}
  @type summary :: %{actions: section(), states: section(), transitions: section()}

  @unreached_cap 20

  @doc """
  Builds an empty accumulator and computes the graph's totals up front.
  `external_actions` is the mapping's `actions/0` keys (the driven actions);
  `internal` is its declared internal actions (Notary design spec §4.3).
  """
  @spec new(StateGraph.t(), [String.t()], [String.t()], [String.t()]) :: t()
  def new(%StateGraph{} = graph, observe, internal, external_actions) do
    external = MapSet.new(external_actions)
    named = MapSet.union(external, MapSet.new(internal))
    actions_total = MapSet.intersection(graph.actions, named)

    states_total =
      graph.states |> Map.keys() |> Enum.map(&project_state(graph, &1, observe)) |> MapSet.new()

    transitions_total =
      graph
      |> StateGraph.edges()
      |> Enum.filter(fn {_from, action, _to} -> MapSet.member?(external, action) end)
      |> Enum.map(fn {from, action, to} ->
        {project_state(graph, from, observe), action, project_state(graph, to, observe)}
      end)
      |> MapSet.new()

    %__MODULE__{
      graph: graph,
      observe: observe,
      internal: internal,
      actions_total: actions_total,
      states_total: states_total,
      transitions_total: transitions_total
    }
  end

  @doc """
  Folds one run's steps (as returned by `Notary.Conformance.Runner.run/8`)
  into the accumulator.

  **States**: every step's `projection` is added, regardless of outcome.

  **Transitions**: for each consecutive pair of steps where the later one was
  accepted (`outcome: :ok`) and names a real action (not the initial step,
  not a `(settle)` step), `{prev.projection, action, projection}` is added.

  **Actions**: an external action is added whenever some step accepted it.
  An internal action is credited following the design spec §5.2 rule: for
  each step after the initial one, let `C_prev` be the previous step's
  `candidates` and
    * `E := successors(Walk.closure(graph, C_prev, internal), action)` if
      this step accepted an external action, or
    * `E := C_prev` if this step is a `(settle)` step or was rejected.

  If this step's `candidates` and `E` are disjoint (the implementation could
  only have gotten here via one or more internal actions), every internal
  action `a` labelling an edge `(u, a, t)` with `u` in
  `Walk.closure(graph, E, internal)` and `t` in this step's `candidates` is
  credited as reached.
  """
  @spec add_run(t(), [Step.t()]) :: t()
  def add_run(%__MODULE__{} = cov, steps) do
    cov
    |> add_states(steps)
    |> add_transitions(steps)
    |> add_external_actions(steps)
    |> add_internal_actions(steps)
  end

  defp add_states(cov, steps) do
    projections = Enum.map(steps, & &1.projection)
    %{cov | states_reached: MapSet.union(cov.states_reached, MapSet.new(projections))}
  end

  defp add_transitions(cov, steps) do
    reached =
      steps
      |> Enum.zip(tl_or_empty(steps))
      |> Enum.filter(fn {_prev, cur} -> accepted_real_action?(cur) end)
      |> Enum.map(fn {prev, cur} -> {prev.projection, cur.action, cur.projection} end)
      |> MapSet.new()

    %{cov | transitions_reached: MapSet.union(cov.transitions_reached, reached)}
  end

  defp add_external_actions(cov, steps) do
    reached =
      steps
      |> Enum.filter(&accepted_real_action?/1)
      |> Enum.map(& &1.action)
      |> MapSet.new()

    %{cov | actions_reached: MapSet.union(cov.actions_reached, reached)}
  end

  defp add_internal_actions(cov, steps) do
    pairs = Enum.zip(steps, tl_or_empty(steps))
    Enum.reduce(pairs, cov, fn {prev, cur}, acc -> add_internal_for_pair(acc, prev, cur) end)
  end

  defp add_internal_for_pair(cov, prev, cur) do
    c_prev = prev.candidates
    e = reachable_without_internal(cov, c_prev, cur)

    if disjoint?(cur.candidates, e) do
      reached = internal_actions_into(cov, e, cur.candidates)
      %{cov | actions_reached: MapSet.union(cov.actions_reached, reached)}
    else
      cov
    end
  end

  # Accepted real action: direct successors from the closure of C_prev via
  # that action (no internal hops taken yet). Settle or rejected: C_prev
  # itself (no external transition happened).
  defp reachable_without_internal(cov, c_prev, cur) do
    if accepted_real_action?(cur) do
      closed = Walk.closure(cov.graph, c_prev, cov.internal)
      closed |> Enum.flat_map(&StateGraph.successors(cov.graph, &1, cur.action)) |> Enum.uniq()
    else
      c_prev
    end
  end

  defp internal_actions_into(cov, e, candidates) do
    closed_e = Walk.closure(cov.graph, e, cov.internal)

    for u <- closed_e,
        a <- cov.internal,
        t <- StateGraph.successors(cov.graph, u, a),
        t in candidates,
        into: MapSet.new(),
        do: a
  end

  defp accepted_real_action?(%Step{index: 0}), do: false
  defp accepted_real_action?(%Step{action: nil}), do: false
  defp accepted_real_action?(%Step{action: "(settle)"}), do: false
  defp accepted_real_action?(%Step{outcome: :ok}), do: true
  defp accepted_real_action?(_step), do: false

  defp disjoint?(a, b), do: MapSet.disjoint?(MapSet.new(a), MapSet.new(b))

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | rest]), do: rest

  defp project_state(graph, id, observe), do: graph |> StateGraph.state(id) |> Map.take(observe)

  @doc "Summarizes the accumulator as reached/total/unreached per category."
  @spec summary(t()) :: summary()
  def summary(%__MODULE__{} = cov) do
    %{
      actions: section(cov.actions_total, cov.actions_reached),
      states: section(cov.states_total, cov.states_reached),
      transitions: section(cov.transitions_total, cov.transitions_reached)
    }
  end

  defp section(total_set, reached_set) do
    reached_count = MapSet.size(MapSet.intersection(total_set, reached_set))

    unreached =
      total_set |> MapSet.difference(reached_set) |> Enum.sort() |> Enum.take(@unreached_cap)

    %{reached: reached_count, total: MapSet.size(total_set), unreached: unreached}
  end
end
