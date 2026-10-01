defmodule Outlaw.Conformance.Walk do
  @moduledoc """
  Spec-guided generation (Outlaw design spec §5.1): walks the spec's state
  graph to build StreamData generators of conformance-run steps, instead of
  picking uniformly at random from `actions/0` (`generation: :uniform`, see
  `Outlaw.Conformance.Runner.steps_generator/2`).

  Pure: no processes, no global/persistent state. Shortest-path results are
  memoized in a local map built once per `generator/3` call (see
  `generator/3`'s `@doc`), not shared across calls.
  """

  alias Outlaw.{Config, StateGraph}

  @type possible :: [StateGraph.state_id()]

  @doc """
  Every state reachable from `state_ids` through zero or more edges labelled
  with one of `internal`'s action names (Outlaw design spec §4.3). With
  `internal: []` this is `state_ids` itself (same list, same order).
  """
  @spec closure(StateGraph.t(), [StateGraph.state_id()], [String.t()]) :: [StateGraph.state_id()]
  def closure(_graph, state_ids, []), do: state_ids

  def closure(graph, state_ids, internal) do
    state_ids |> MapSet.new() |> closure_fixpoint(graph, internal) |> MapSet.to_list()
  end

  defp closure_fixpoint(set, graph, internal) do
    grown =
      Enum.reduce(internal, set, fn name, acc ->
        Enum.reduce(set, acc, fn s, acc2 ->
          graph |> StateGraph.successors(s, name) |> Enum.reduce(acc2, &MapSet.put(&2, &1))
        end)
      end)

    if MapSet.equal?(grown, set), do: set, else: closure_fixpoint(grown, graph, internal)
  end

  @doc """
  The §5.1 possible-set rule: `closure(successors(possible, action))`, or
  `possible` unchanged if `action` is enabled nowhere in `possible` (the
  implementation must reject it).
  """
  @spec advance(StateGraph.t(), possible(), String.t(), [String.t()]) :: possible()
  def advance(graph, possible, action, internal) do
    case possible |> Enum.flat_map(&StateGraph.successors(graph, &1, action)) |> Enum.uniq() do
      [] -> possible
      successors -> closure(graph, successors, internal)
    end
  end

  @doc """
  BFS over edges labelled with one of `external_actions`, from any of
  `from_states`, to `target_state`, taking closure under every other graph
  action (treated as internal for this purpose: `graph.actions --
  external_actions`) at every node — so a target reachable from a node's
  closure needs no further external action. Returns the shortest list of
  external action names, or `nil` if `target_state` isn't reachable this way.
  """
  @spec shortest_path(StateGraph.t(), [StateGraph.state_id()], StateGraph.state_id(), [
          String.t()
        ]) :: [String.t()] | nil
  def shortest_path(graph, from_states, target_state, external_actions) do
    internal = MapSet.difference(graph.actions, MapSet.new(external_actions)) |> MapSet.to_list()
    actions = Enum.sort(external_actions)
    start = Enum.uniq(from_states)
    closed_start = closure(graph, start, internal)

    if target_state in closed_start do
      []
    else
      queue = :queue.from_list(Enum.map(start, &{&1, []}))
      bfs(graph, queue, MapSet.new(start), internal, actions, target_state)
    end
  end

  defp bfs(graph, queue, visited, internal, actions, target) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, {state, path}}, rest} ->
        closed = closure(graph, [state], internal)

        if target in closed do
          path
        else
          {new_queue, new_visited} =
            Enum.reduce(actions, {rest, visited}, fn action, {q, vis} ->
              closed
              |> Enum.flat_map(&StateGraph.successors(graph, &1, action))
              |> Enum.uniq()
              |> Enum.reduce({q, vis}, fn t, {q2, vis2} ->
                if MapSet.member?(vis2, t) do
                  {q2, vis2}
                else
                  {:queue.in({t, path ++ [action]}, q2), MapSet.put(vis2, t)}
                end
              end)
            end)

          bfs(graph, new_queue, new_visited, internal, actions, target)
        end
    end
  end

  @doc """
  Builds the spec-guided generator (Outlaw design spec §5.1): each value
  picks a target transition uniformly among all graph edges (internal
  included), emits the shortest external-action path to its source (skipping
  targets unreachable via external actions), then the target action (if
  external) or a `:settle` point (if internal), then continues with a random
  walk up to `max_steps` total items.

  `actions` is the mapping's `actions/0` map. `opts`:
    * `:internal` — declared internal action names (default `[]`).
    * `:fair` — `MapSet` of the declared internal actions the spec marks fair
      (default `MapSet.new()`); after an emitted action makes one of these
      enabled somewhere in the possible set, the next item is `:settle` with
      probability 1/2.
    * `:max_steps` — default `Outlaw.Config.get(:max_steps)`.

  Shortest paths are memoized in a plain map built once here (keyed by
  source state, since every edge out of the same state shares the same
  path), not in any process-wide or persistent cache.
  """
  @spec generator(StateGraph.t(), %{String.t() => StreamData.t(map())}, keyword()) ::
          StreamData.t([{String.t(), map()} | :settle])
  def generator(graph, actions, opts \\ []) do
    internal = Keyword.get(opts, :internal, [])
    fair = Keyword.get(opts, :fair, MapSet.new())
    max_steps = Keyword.get(opts, :max_steps, Config.get(:max_steps))
    external_actions = actions |> Map.keys() |> Enum.sort()
    closed_initial = closure(graph, StateGraph.initial_states(graph), internal)
    edges = StateGraph.edges(graph)

    path_cache =
      edges
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Map.new(&{&1, shortest_path(graph, closed_initial, &1, external_actions)})

    entries =
      edges
      |> Enum.map(fn {from, action, _to} -> {Map.fetch!(path_cache, from), action} end)
      |> Enum.reject(fn {path, _action} -> is_nil(path) end)

    case entries do
      [] ->
        StreamData.constant([])

      _ ->
        StreamData.bind(StreamData.member_of(entries), fn {path, target_action} ->
          target_value(
            graph,
            actions,
            external_actions,
            internal,
            fair,
            closed_initial,
            path,
            target_action,
            max_steps
          )
        end)
    end
  end

  # -- target: shortest path + target action/settle, then the random walk ----

  defp target_value(
         graph,
         actions,
         external_actions,
         internal,
         fair,
         closed_initial,
         path,
         target_action,
         max_steps
       ) do
    names =
      if Map.has_key?(actions, target_action),
        do: path ++ [target_action],
        else: path ++ [:settle]

    take_count = min(max_steps, length(names))
    prefix_names = Enum.take(names, take_count)

    possible_after =
      Enum.reduce(prefix_names, closed_initial, &apply_name(graph, internal, &2, &1))

    remaining = max_steps - take_count

    force_initial? =
      case List.last(prefix_names) do
        nil -> false
        :settle -> false
        _ -> any_fair_enabled?(graph, possible_after, fair)
      end

    prefix_gen =
      prefix_names
      |> Enum.map(fn
        :settle -> StreamData.constant(:settle)
        name -> StreamData.map(Map.fetch!(actions, name), &{name, &1})
      end)
      |> StreamData.fixed_list()

    continuation_gen =
      continuation(
        graph,
        actions,
        external_actions,
        internal,
        fair,
        possible_after,
        remaining,
        force_initial?
      )

    StreamData.map(StreamData.tuple({prefix_gen, continuation_gen}), fn {p, c} -> p ++ c end)
  end

  defp apply_name(_graph, _internal, possible, :settle), do: possible
  defp apply_name(graph, internal, possible, name), do: advance(graph, possible, name, internal)

  # -- continue: random walk up to max_steps total items ----------------------

  defp continuation(_graph, _actions, _external, _internal, _fair, _possible, remaining, _force?)
       when remaining <= 0 do
    StreamData.constant([])
  end

  defp continuation(graph, actions, external_actions, internal, fair, possible, remaining, force?) do
    next_item_generator(graph, actions, external_actions, possible, force?)
    |> StreamData.bind(fn item ->
      {new_possible, new_force?} = apply_item(graph, internal, fair, possible, item)

      continuation(
        graph,
        actions,
        external_actions,
        internal,
        fair,
        new_possible,
        remaining - 1,
        new_force?
      )
      |> StreamData.bind(&StreamData.constant([item | &1]))
    end)
  end

  defp apply_item(_graph, _internal, _fair, possible, :settle), do: {possible, false}

  defp apply_item(graph, internal, fair, possible, {name, _params}) do
    new_possible = advance(graph, possible, name, internal)
    {new_possible, any_fair_enabled?(graph, new_possible, fair)}
  end

  defp next_item_generator(graph, actions, external_actions, possible, force?) do
    normal_gen = fn -> weighted_item_generator(graph, actions, external_actions, possible) end

    if force? do
      StreamData.bind(StreamData.member_of([:force, :skip]), fn
        :force -> StreamData.constant(:settle)
        :skip -> normal_gen.()
      end)
    else
      normal_gen.()
    end
  end

  defp weighted_item_generator(graph, actions, external_actions, possible) do
    enabled = Enum.filter(external_actions, &enabled_somewhere?(graph, possible, &1))
    disabled = external_actions -- enabled

    enabled_bucket = action_bucket(80, enabled, disabled, actions)
    disabled_bucket = action_bucket(15, disabled, enabled, actions)
    settle_bucket = {5, StreamData.constant(:settle)}

    [enabled_bucket, disabled_bucket, settle_bucket]
    |> Enum.reject(&is_nil/1)
    |> StreamData.frequency()
  end

  defp action_bucket(weight, primary, fallback, actions) do
    case {primary, fallback} do
      {[], []} -> nil
      {[], _} -> {weight, action_generator(actions, fallback)}
      {_, _} -> {weight, action_generator(actions, primary)}
    end
  end

  defp action_generator(actions, names) do
    StreamData.bind(StreamData.member_of(names), fn name ->
      StreamData.map(Map.fetch!(actions, name), &{name, &1})
    end)
  end

  defp enabled_somewhere?(graph, possible, action),
    do: Enum.any?(possible, &(StateGraph.successors(graph, &1, action) != []))

  defp any_fair_enabled?(graph, possible, fair),
    do: Enum.any?(fair, &enabled_ignoring_self_loops?(graph, possible, &1))

  defp enabled_ignoring_self_loops?(graph, possible, action) do
    Enum.any?(possible, fn s ->
      graph |> StateGraph.successors(s, action) |> Enum.any?(&(&1 != s))
    end)
  end
end
