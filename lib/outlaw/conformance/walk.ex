defmodule Outlaw.Conformance.Walk do
  @moduledoc """
  Spec-guided generation (Outlaw design spec §5.1): walks the spec's state
  graph to build StreamData generators of conformance-run steps, instead of
  picking uniformly at random from `actions/0` (`generation: :uniform`, see
  `Outlaw.Conformance.Runner.steps_generator/2`).

  Pure: no processes, no global/persistent state. `shortest_path/5` runs a
  single BFS with parent pointers over the external-action edges, not one
  per target; `generator/3` runs it once per build and reconstructs every
  needed path from the parent map in O(path length) each — no repeated
  per-target re-search. The BFS visits each state at most once and is O(V+E)
  in the external-action edges, but it also computes `closure/3` once for
  each newly-discovered state (to alias its closure-mates onto the same
  parent pointer, see `discover/6`); since that's a fresh fixpoint computation
  per discovery rather than a memoized lookup, the worst case across a run
  with many internal-action edges is O(V·(V+E_internal)), not O(V+E) — fine
  for the graph sizes Outlaw deals with, but not asymptotically tight.

  ## Generator shape (why it's built this way)

  A value is drawn as plain data —
  `%{targeted?: boolean(), target_index: non_neg_integer(), tokens: [token]}`
  (a "token" bundles one step's random choices: a weighted bucket roll, a
  pick index, a settle-bias roll, and params per action) — and then
  `StreamData.map/2` *folds* that data into the actual `[{name, params} |
  :settle]` list by simulating the walk deterministically against it. This
  (rather than a chain of nested `StreamData.bind/2` calls simulating the
  walk step-by-step as randomness is drawn) is what makes values shrink like
  lists: `tokens` is an ordinary `StreamData.list_of/2`, so StreamData can
  delete a token to shorten the value, and the fold naturally reprocesses a
  shorter, still-consistent sequence — the previous nested-bind design
  produced values of exactly `max_steps` items that could never shrink
  shorter (only each item's own choice could shrink, regenerating its entire
  tail). `targeted?` shrinks to `false` (dropping the prefix entirely), so a
  minimal failing trace doesn't have to drag a shortest-path prefix along.

  Deleting one token doesn't just shorten the value by one item — because
  each continuation token's `pick_index` is read modulo the *current*
  enabled/disabled list's length, and that list depends on the possible set
  `P` at that position, removing an earlier token can shift every later
  token into a different position against a different `P`, which can
  reinterpret the same `pick_index`/`bucket` roll into a different action
  entirely. This is expected and harmless for shrinking (StreamData just
  checks whether the resulting, possibly-different value still fails), but
  means a shrunk value's tokens shouldn't be read as "the same choices with
  one removed."

  If `generator/3` finds no reachable, declared-action target edge at all
  (an empty `entries` list — e.g. a graph with no edges from the initial
  state under the declared external/internal actions), `targeted?` and
  `target_index` are simply never consulted and every value is pure
  continuation from `closure(initial)`: the generator degrades to the
  random walk described below with no targeted prefix, rather than failing.

  ## Forced settle (fair internal actions)

  After emitting an action `a`, the walk checks the *direct* successors of
  the possible set `P` via `a` — `successors(P, a)`, *before* taking closure
  under internal actions — for a state where some fair internal action
  (`opts[:fair]`) is enabled (self-loops excluded). Only then does the
  *next* token's settle-bias roll get a chance to force `:settle`
  (probability 1/2); otherwise it's ignored and the token resolves normally.

  This checks the pre-closure landing states deliberately, not whether `P`
  itself (already closure-including) currently contains such a state: `P` is
  always closed under internal actions, so once a pending reaction is first
  exposed it stays visible in `P` forever (closure never removes anything).
  Checking against `P` itself would therefore fire the bias at most once per
  generated value no matter how many times the triggering action recurs
  (e.g. in a spec with `pending --Request--> pending` self-looping into a
  state that always keeps a reaction enabled, every `Request` after the
  first would look like "no change" against `P`). Checking the raw landing
  states of the just-emitted action instead fires every time that action
  lands somewhere exposing the reaction, including repeat visits to the same
  enabling state — e.g. for the Async fixture (`internal: ["Complete"]`,
  `fair: MapSet.new(["Complete"])`), every `Request` lands (before closure)
  on the `pending` state, where `Complete` is enabled, so the bias is
  eligible after *every* `Request`, not just the first.

  "Enabled" ignores self-loops (a successor equal to the source state),
  matching `Outlaw.Conformance.Runner`'s settling check — a self-loop can
  never be observed, so it can never trigger (or block) a settle.
  """

  alias Outlaw.{Config, StateGraph}

  @type possible :: [StateGraph.state_id()]
  @type token :: %{
          bucket: :enabled | :disabled | :settle,
          pick_index: non_neg_integer(),
          settle_bias: boolean(),
          params: %{String.t() => map()}
        }

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
  Shortest external-action path from any of `from_states` to `target_state`,
  taking closure under `internal` at every node (so a target already in a
  visited node's internal closure needs no further external action). `[]`
  means `target_state` is already in `closure(from_states, internal)`; `nil`
  means it's unreachable this way.

  Runs a single BFS from `closure(from_states, internal)` with parent
  pointers, visiting each state at most once (O(V+E) in the external-action
  edges, plus one closure computation per newly-discovered state — see the
  moduledoc for why that isn't a flat O(V+E) in the presence of internal
  actions), then reconstructs the path by walking parents backward once — no
  per-target re-search, no repeated list-append while searching.
  """
  @spec shortest_path(
          StateGraph.t(),
          [StateGraph.state_id()],
          StateGraph.state_id(),
          [
            String.t()
          ],
          [String.t()]
        ) :: [String.t()] | nil
  def shortest_path(graph, from_states, target_state, external_actions, internal) do
    closed_start = closure(graph, Enum.uniq(from_states), internal)
    parents = bfs_parents(graph, closed_start, internal, external_actions)
    reconstruct_path(parents, target_state)
  end

  # Single-source-set BFS building a parent-pointer map: state_id => :root
  # (one of the start states, already closed) or {prev_state_id, action}
  # (reached from prev_state_id via action). A state absent from the map was
  # never visited (unreachable).
  #
  # When a brand-new state `t` is discovered via `action` from `from`, every
  # member of `closure([t], internal)` is registered with the *same* parent
  # pointer `{from, action}` and enqueued individually — they're all reached
  # by the same external path (the internal hops to reach them are free).
  # Every member therefore gets its own turn to explore its own direct
  # successors, which together cover the same ground as exploring from the
  # whole closure at once, without recomputing it at every pop.
  defp bfs_parents(graph, closed_start, internal, external_actions) do
    bfs_parents(graph, closed_start, internal, external_actions, rank_map(graph))
  end

  # Same BFS, but taking a precomputed rank map (state id -> position in
  # content order, see `rank_map/1`) instead of computing its own -- so a
  # caller building many parent maps against the same graph (`generator/3`)
  # pays for the content sort once, not per call.
  #
  # Every ordering choice the BFS makes is driven by `rank`, never raw ids:
  # the initial frontier, each popped state's successors (per action), and
  # the members of a freshly-discovered state's closure are all visited in
  # rank order before being folded into the queue/parents accumulator. Ids
  # are TLC fingerprints that change on every fresh TLC run, so without this
  # the parent map built here -- and therefore which path `generator/3` picks
  # whenever two equally-short paths exist -- would depend on those arbitrary
  # ids instead of only on the graph's actual shape (item 1).
  defp bfs_parents(graph, closed_start, internal, external_actions, rank) do
    actions = Enum.sort(external_actions)
    parents = Map.new(closed_start, &{&1, :root})
    queue = closed_start |> by_rank(rank) |> :queue.from_list()
    bfs_parents_loop(graph, queue, parents, internal, actions, rank)
  end

  defp bfs_parents_loop(graph, queue, parents, internal, actions, rank) do
    case :queue.out(queue) do
      {:empty, _} ->
        parents

      {{:value, state}, rest} ->
        {new_queue, new_parents} =
          Enum.reduce(actions, {rest, parents}, fn action, {q, par} ->
            graph
            |> StateGraph.successors(state, action)
            |> by_rank(rank)
            |> Enum.reduce({q, par}, &discover(graph, internal, state, action, &1, &2, rank))
          end)

        bfs_parents_loop(graph, new_queue, new_parents, internal, actions, rank)
    end
  end

  defp discover(graph, internal, from, action, target, {queue, parents}, rank) do
    if Map.has_key?(parents, target) do
      {queue, parents}
    else
      graph
      |> closure([target], internal)
      |> by_rank(rank)
      |> Enum.reduce({queue, parents}, fn alias_state, {q, par} ->
        if Map.has_key?(par, alias_state) do
          {q, par}
        else
          {:queue.in(alias_state, q), Map.put(par, alias_state, {from, action})}
        end
      end)
    end
  end

  # Content-order sort for a list of state ids, given a precomputed rank map
  # (see `rank_map/1`). Ties (equal state content under different ids, which
  # TLC should never actually produce as distinct states) fall back to
  # whatever relative order the list already had -- `Enum.sort_by/2` is
  # stable -- rather than to the ids themselves.
  defp by_rank(ids, rank), do: Enum.sort_by(ids, &Map.fetch!(rank, &1))

  # Maps every state id in `graph` to its position in content order (`Enum.
  # sort_by(ids, &StateGraph.state(graph, &1))`) -- a total order over ids
  # driven entirely by the states' own variable assignments, never by the
  # (TLC-fingerprint, arbitrary-per-run) ids themselves. Computed once per
  # `generator/3` build and threaded through every ordering decision that
  # would otherwise depend on id order (item 1).
  @spec rank_map(StateGraph.t()) :: %{StateGraph.state_id() => non_neg_integer()}
  defp rank_map(graph) do
    graph.states
    |> Map.keys()
    |> Enum.sort_by(&StateGraph.state(graph, &1))
    |> Enum.with_index()
    |> Map.new()
  end

  # Walks parent pointers backward from `state`, prepending each action as it
  # goes — by construction this yields the actions in forward order with no
  # list concatenation (`++`) anywhere in the walk.
  defp reconstruct_path(parents, state), do: reconstruct_path(parents, state, [])

  defp reconstruct_path(parents, state, acc) do
    case Map.fetch(parents, state) do
      :error -> nil
      {:ok, :root} -> acc
      {:ok, {prev, action}} -> reconstruct_path(parents, prev, [action | acc])
    end
  end

  @doc """
  Builds the spec-guided generator (Outlaw design spec §5.1 — see the
  moduledoc for why the generator is shaped the way it is). `actions` is the
  mapping's `actions/0` map. `opts`:
    * `:internal` — declared internal action names (default `[]`).
    * `:fair` — `MapSet` of the declared internal actions the spec marks fair
      (default `MapSet.new()`).
    * `:max_steps` — default `Outlaw.Config.get(:max_steps)`.
  """
  @spec generator(StateGraph.t(), %{String.t() => StreamData.t(map())}, keyword()) ::
          StreamData.t([{String.t(), map()} | :settle])
  def generator(graph, actions, opts \\ []) do
    internal = Keyword.get(opts, :internal, [])
    fair = Keyword.get(opts, :fair, MapSet.new())
    max_steps = Keyword.get(opts, :max_steps, Config.get(:max_steps))
    external_actions = actions |> Map.keys() |> Enum.sort()
    allowed_actions = MapSet.new(external_actions ++ internal)
    closed_initial = closure(graph, StateGraph.initial_states(graph), internal)
    rank = rank_map(graph)
    parents = bfs_parents(graph, closed_initial, internal, external_actions, rank)

    entries =
      graph
      |> StateGraph.edges()
      |> Enum.filter(fn {_from, action, _to} -> MapSet.member?(allowed_actions, action) end)
      |> Enum.sort_by(fn {from, action, to} ->
        {Map.fetch!(rank, from), action, Map.fetch!(rank, to)}
      end)
      |> Enum.map(fn {from, action, _to} -> {reconstruct_path(parents, from), action} end)
      |> Enum.reject(fn {path, _action} -> is_nil(path) end)

    raw_gen =
      StreamData.fixed_map(%{
        targeted?: StreamData.boolean(),
        target_index: StreamData.non_negative_integer(),
        tokens: StreamData.list_of(token_generator(actions), max_length: max_steps)
      })

    StreamData.map(raw_gen, fn raw ->
      fold(graph, actions, external_actions, internal, fair, closed_initial, entries, raw)
    end)
  end

  defp token_generator(actions) do
    StreamData.fixed_map(%{
      bucket:
        StreamData.frequency([
          {80, StreamData.constant(:enabled)},
          {15, StreamData.constant(:disabled)},
          {5, StreamData.constant(:settle)}
        ]),
      pick_index: StreamData.non_negative_integer(),
      settle_bias: StreamData.boolean(),
      params: StreamData.fixed_map(actions)
    })
  end

  # -- fold: raw {targeted?, target_index, tokens} -> [{name, params} | :settle] --

  defp fold(graph, actions, external_actions, internal, fair, closed_initial, entries, raw) do
    %{targeted?: targeted?, target_index: target_index, tokens: tokens} = raw

    {prefix_names, prefix_tokens, rest_tokens} =
      prefix_plan(actions, entries, targeted?, target_index, tokens)

    {prefix_items, {possible_after, force_initial?}} =
      prefix_names
      |> Enum.zip(prefix_tokens)
      |> Enum.map_reduce({closed_initial, false}, fn
        {:settle, _token}, {possible, _force?} ->
          {:settle, {possible, false}}

        {name, token}, {possible, _force?} ->
          params = Map.fetch!(token.params, name)
          new_possible = advance(graph, possible, name, internal)
          {{name, params}, {new_possible, triggers_fair?(graph, possible, name, fair)}}
      end)

    {continuation_rev, _possible, _force?} =
      Enum.reduce(rest_tokens, {[], possible_after, force_initial?}, fn token,
                                                                        {acc, possible, force?} ->
        {item, new_possible, new_force?} =
          resolve_token(graph, external_actions, internal, fair, possible, force?, token)

        {[item | acc], new_possible, new_force?}
      end)

    prefix_items ++ Enum.reverse(continuation_rev)
  end

  # Only if `targeted?` and there's at least one reachable, declared-action
  # entry: picks one uniformly (via `target_index mod length(entries)`),
  # builds its deterministic name sequence (shortest path, then the target
  # action or `:settle` if the target action is internal), and truncates it
  # to however many tokens are actually available (shrinking `tokens` below
  # the prefix's natural length just truncates the run early, same as
  # running out of `max_steps`).
  defp prefix_plan(actions, entries, targeted?, target_index, tokens) do
    if targeted? and entries != [] do
      {path, target_action} = Enum.at(entries, rem(target_index, length(entries)))

      names =
        if Map.has_key?(actions, target_action),
          do: path ++ [target_action],
          else: path ++ [:settle]

      take = min(length(names), length(tokens))
      prefix_names = Enum.take(names, take)
      {prefix_tokens, rest_tokens} = Enum.split(tokens, take)
      {prefix_names, prefix_tokens, rest_tokens}
    else
      {[], [], tokens}
    end
  end

  # -- continuation: one token -> one item, weighted by the current P --------

  defp resolve_token(graph, external_actions, internal, fair, possible, force?, token) do
    item = pick_item(graph, external_actions, possible, force?, token)
    new_possible = apply_item(graph, internal, possible, item)
    {item, new_possible, next_force?(graph, possible, fair, item)}
  end

  defp apply_item(_graph, _internal, possible, :settle), do: possible

  defp apply_item(graph, internal, possible, {name, _params}),
    do: advance(graph, possible, name, internal)

  defp next_force?(_graph, _possible, _fair, :settle), do: false

  defp next_force?(graph, possible, fair, {name, _params}),
    do: triggers_fair?(graph, possible, name, fair)

  # Whether emitting `name` from `possible` lands (via `successors/3`
  # directly, *before* taking closure under internal actions) on a state
  # where some fair internal action is enabled (self-loops excluded). See
  # the moduledoc's "Forced settle" section for why this must be checked
  # against the raw landing states rather than the (always closure-including)
  # possible set itself.
  defp triggers_fair?(graph, possible, name, fair) do
    possible
    |> Enum.flat_map(&StateGraph.successors(graph, &1, name))
    |> Enum.uniq()
    |> then(&any_fair_enabled?(graph, &1, fair))
  end

  defp pick_item(graph, external_actions, possible, force?, token) do
    if force? and token.settle_bias do
      :settle
    else
      enabled = Enum.filter(external_actions, &enabled_somewhere?(graph, possible, &1))
      disabled = external_actions -- enabled

      case resolve_bucket(token.bucket, enabled, disabled) do
        :settle ->
          :settle

        names ->
          name = Enum.at(names, rem(token.pick_index, length(names)))
          {name, Map.fetch!(token.params, name)}
      end
    end
  end

  # Weights 80 enabled-somewhere-in-P (if none, fall back to disabled), 15
  # disabled-everywhere-in-P (if none, fall back to enabled), 5 settle —
  # Outlaw design spec §5.1's "Continue" weights.
  defp resolve_bucket(:settle, _enabled, _disabled), do: :settle

  defp resolve_bucket(:enabled, enabled, disabled) do
    cond do
      enabled != [] -> enabled
      disabled != [] -> disabled
      true -> :settle
    end
  end

  defp resolve_bucket(:disabled, enabled, disabled) do
    cond do
      disabled != [] -> disabled
      enabled != [] -> enabled
      true -> :settle
    end
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
