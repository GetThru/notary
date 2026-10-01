defmodule Outlaw.Conformance.Runner do
  @moduledoc """
  Drives an implementation through generated action sequences and checks every
  step against the spec's state graph (see the Outlaw spec §5). Each run happens
  in a fresh process, which exits with `:shutdown` afterwards so processes linked
  to it by `init/0` are cleaned up.
  """

  alias Outlaw.{Config, StateGraph, Value}
  alias Outlaw.Conformance.{Failure, Step, Walk}

  @default_max_replays 200
  @spec_level_kinds [
    :init_mismatch,
    :illegal_transition,
    :action_not_enabled,
    :rejected_with_side_effect
  ]

  @spec check(module(), StateGraph.t(), [String.t()], keyword()) ::
          {:ok, %{runs: non_neg_integer(), seed: integer()}} | {:error, Failure.t()}
  def check(module, graph, observe, opts) do
    seed = Keyword.get_lazy(opts, :seed, fn -> :rand.uniform(1_000_000) end)
    max_runs = Keyword.get(opts, :max_runs, Config.get(:max_runs))
    max_steps = Keyword.get(opts, :max_steps, Config.get(:max_steps))
    timeout = Keyword.get(opts, :action_timeout, Config.get(:action_timeout))
    settle_timeout = Keyword.get(opts, :settle_timeout, Config.get(:settle_timeout))
    internal = Map.get(module.__outlaw__(), :internal, [])
    fair = Keyword.get(opts, :fair, MapSet.new())
    generation = Map.get(module.__outlaw__(), :generation, :walk)

    generator = generator(generation, module, graph, internal, fair, max_steps)
    options = [initial_seed: {0, 0, seed}, max_runs: max_runs, max_shrinking_steps: 500]

    result =
      StreamData.check_all(generator, options, fn items ->
        case run(module, graph, observe, internal, fair, items, timeout, settle_timeout) do
          {:ok, _steps} -> {:ok, nil}
          {:error, failure} -> {:error, {items, failure}}
        end
      end)

    case result do
      {:ok, _} ->
        {:ok, %{runs: max_runs, seed: seed}}

      {:error, %{shrunk_failure: {items, failure}}} ->
        replay = &run(module, graph, observe, internal, fair, &1, timeout, settle_timeout)

        {_items, failure, stats} =
          minimize(items, failure, replay,
            seed: seed,
            actions: module.actions(),
            max_replays: Keyword.get(opts, :max_replays, @default_max_replays)
          )

        details = Map.put(failure.details, :minimized, format_stats(stats))
        {:error, %{failure | seed: seed, details: details}}
    end
  end

  defp format_stats(%{replays: r, removed: d, params: p}),
    do: "#{r} replays, #{d} items removed, #{p} params reduced"

  # -- post-shrink minimization (Outlaw design spec §5.1) ----------------------

  @doc """
  Minimizes a failing item list after StreamData's own shrinking (design spec
  §5.1, "Reproducibility and shrinking"). The spec-guided generator's values
  don't keep their identity when StreamData deletes a token (later tokens get
  reinterpreted against a different possible set), so its shrinking can stop
  at a long trace; this pass works on the concrete `{name, params}` /
  `:settle` items instead, where deleting one item leaves the others intact.

  Repeats, until a round changes nothing or the replay budget runs out:
    * deletion: tries removing contiguous chunks (halves, quarters, ... then
      single items, front to back), keeping a removal whenever the
      candidate still fails (below);
    * params: for each `{name, params}` item, tries values drawn from
      `name`'s params generator in `opts[:actions]` that are smaller than the
      current params in Erlang term order (a structural order, not a
      domain-specific "simpler" -- e.g. `%{a: 1} < %{a: 2}`), smallest
      first, keeping the first one that still fails.

  A candidate "still fails" only if its replay fails with the original
  failure's kind, or both kinds are spec-level (`:init_mismatch`,
  `:illegal_transition`, `:action_not_enabled`,
  `:rejected_with_side_effect`): e.g. an `:illegal_transition` that needed a
  preceding step can become an `:action_not_enabled` without it, but a spec
  violation is never traded for a `:timeout`, `:crashed`, `:exception` or
  `:internal_action_stalled` (an unrelated or flaky defect). Returns
  the minimized items, the `Failure` from the last failing replay (or the
  given one if nothing was removed or reduced) and
  `%{replays:, removed:, params:}`.

  Options: `:seed` (integer; drives params candidate draws, default 0),
  `:actions` (params generators, default `%{}`: no params pass),
  `:max_replays` (default #{@default_max_replays}; each replay can cost up
  to `action_timeout` per step plus `settle_timeout` per settle point, so
  this bounds the pass; `Runner.check/4` takes it as `:max_replays`).
  """
  @spec minimize(
          [{String.t(), map()} | :settle],
          Failure.t(),
          ([{String.t(), map()} | :settle] -> {:ok, term()} | {:error, Failure.t()}),
          keyword()
        ) ::
          {[{String.t(), map()} | :settle], Failure.t(),
           %{replays: non_neg_integer(), removed: non_neg_integer(), params: non_neg_integer()}}
  def minimize(items, failure, replay, opts \\ []) do
    m = %{
      items: items,
      failure: failure,
      original_kind: failure.kind,
      replay: replay,
      seed: Keyword.get(opts, :seed, 0),
      actions: Keyword.get(opts, :actions, %{}),
      budget: Keyword.get(opts, :max_replays, @default_max_replays),
      replays: 0,
      removed: 0,
      params: 0
    }

    m = minimize_rounds(m)
    {m.items, m.failure, Map.take(m, [:replays, :removed, :params])}
  end

  defp minimize_rounds(m) do
    m2 = m |> deletion_pass() |> params_pass()

    if m2.items == m.items or m2.replays >= m2.budget,
      do: m2,
      else: minimize_rounds(m2)
  end

  # Replays `candidate`; on failure it becomes the current items/failure.
  defp try_items(m, candidate) do
    if m.replays >= m.budget do
      {:exhausted, m}
    else
      m = %{m | replays: m.replays + 1}

      case m.replay.(candidate) do
        {:error, failure} ->
          if same_defect?(m.original_kind, failure.kind),
            do: {:fails, %{m | items: candidate, failure: failure}},
            else: {:passes, m}

        _ ->
          {:passes, m}
      end
    end
  end

  # A replay still shows the same defect if it fails with the original kind,
  # or if both kinds are spec-level (the implementation diverged from the
  # spec): e.g. Bank's `:illegal_transition` after a deposit becomes a lone
  # `:action_not_enabled` withdrawal. A spec violation is never traded for a
  # timeout, crash, exception or stall (an unrelated or flaky defect).
  defp same_defect?(kind, kind), do: true

  defp same_defect?(original, kind),
    do: original in @spec_level_kinds and kind in @spec_level_kinds

  defp deletion_pass(m), do: delete_chunks(m, chunk_sizes(length(m.items)))

  defp chunk_sizes(0), do: []
  defp chunk_sizes(1), do: [1]
  defp chunk_sizes(n), do: [div(n, 2) | chunk_sizes(div(n, 2))] |> Enum.uniq()

  defp delete_chunks(m, []), do: m

  defp delete_chunks(m, [size | sizes]) do
    case delete_from(m, size, 0) do
      {:exhausted, m} -> m
      {:done, m} -> delete_chunks(m, sizes)
    end
  end

  defp delete_from(m, size, i) do
    if i >= length(m.items) do
      {:done, m}
    else
      {chunk, rest} = m.items |> Enum.drop(i) |> Enum.split(size)
      candidate = Enum.take(m.items, i) ++ rest

      case try_items(m, candidate) do
        {:exhausted, m} -> {:exhausted, m}
        {:fails, m} -> delete_from(%{m | removed: m.removed + length(chunk)}, size, i)
        {:passes, m} -> delete_from(m, size, i + size)
      end
    end
  end

  defp params_pass(m), do: reduce_params(m, 0)

  defp reduce_params(m, i) do
    if i >= length(m.items) or m.replays >= m.budget do
      m
    else
      case Enum.at(m.items, i) do
        {name, params} when is_map_key(m.actions, name) ->
          m
          |> try_params(i, name, smaller_params(m, i, name, params))
          |> reduce_params(i + 1)

        _ ->
          reduce_params(m, i + 1)
      end
    end
  end

  defp try_params(m, _i, _name, []), do: m

  defp try_params(m, i, name, [params | more]) do
    case try_items(m, List.replace_at(m.items, i, {name, params})) do
      {:fails, m} -> %{m | params: m.params + 1}
      {:passes, m} -> try_params(m, i, name, more)
      {:exhausted, m} -> m
    end
  end

  # Deterministic (from :seed and the item's position) draws from the
  # action's own params generator, so every candidate is a value the mapping
  # can actually be given; only ones smaller than the current params count.
  defp smaller_params(m, i, name, params) do
    gen = Map.fetch!(m.actions, name)

    for k <- 0..15 do
      gen |> StreamData.seeded(:erlang.phash2({m.seed, i, k})) |> Enum.at(0)
    end
    |> Enum.uniq()
    |> Enum.filter(&(&1 < params))
    |> Enum.sort()
  end

  # Design spec §5 step 3 / §5.1: spec-guided by default; `generation:
  # :uniform` keeps the Phase 1 generator exactly (no `:settle` points).
  defp generator(:uniform, module, _graph, _internal, _fair, max_steps),
    do: steps_generator(module.actions(), max_steps)

  defp generator(:walk, module, graph, internal, fair, max_steps) do
    Walk.generator(graph, module.actions(),
      internal: internal,
      fair: MapSet.new(Enum.filter(internal, &MapSet.member?(fair, &1))),
      max_steps: max_steps
    )
  end

  @spec steps_generator(%{String.t() => StreamData.t(map())}, non_neg_integer()) ::
          StreamData.t(list())
  def steps_generator(actions, max_steps) do
    actions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, params} -> StreamData.tuple({StreamData.constant(name), params}) end)
    |> StreamData.one_of()
    |> StreamData.list_of(max_length: max_steps)
  end

  @spec run(
          module(),
          StateGraph.t(),
          [String.t()],
          [String.t()],
          MapSet.t(String.t()),
          [{String.t(), map()} | :settle],
          timeout(),
          timeout()
        ) :: {:ok, [Step.t()]} | {:error, Failure.t()}
  def run(module, graph, observe, internal, fair, steps, timeout, settle_timeout) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]
    fair_internal = Enum.filter(internal, &MapSet.member?(fair, &1))

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        notify = fn event -> send(parent, {ref, :progress, event}) end

        result =
          execute(module, graph, observe, internal, fair_internal, steps, notify, settle_timeout)

        stop_linked_children(timeout)
        send(parent, {ref, :done, result})
        exit(:shutdown)
      end)

    await(%{ref: ref, pid: pid, monitor: monitor, timeout: timeout}, [], nil)
  end

  defp await(w, steps, during) do
    %{ref: ref, pid: pid, monitor: monitor} = w

    receive do
      {^ref, :progress, {:started, label}} ->
        await(w, steps, label)

      {^ref, :progress, :teardown_started} ->
        await(w, steps, during)

      {^ref, :progress, {:step, step}} ->
        await(w, [step | steps], nil)

      {^ref, :done, :ok} ->
        await_down(monitor, pid, w.timeout)
        {:ok, Enum.reverse(steps)}

      {^ref, :done, {:fail, kind, details}} ->
        await_down(monitor, pid, w.timeout)
        {:error, Failure.new(kind, Enum.reverse(steps), Map.put_new(details, :during, during))}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error,
         Failure.new(:crashed, Enum.reverse(steps), %{reason: inspect(reason), during: during})}
    after
      w.timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        flush_ref(ref)

        {:error,
         Failure.new(:timeout, Enum.reverse(steps), %{during: during, timeout: w.timeout})}
    end
  end

  # Waits for the worker's own :DOWN (it has already stopped its linked
  # children by the time it sends :done, see `stop_linked_children/1`) so the
  # next run's init/0 never races a still-dying worker or its process table
  # entry. Bounded by `timeout` as a safety net; falls back to demonitor+flush
  # if the DOWN is somehow delayed past that.
  defp await_down(monitor, pid, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      timeout -> Process.demonitor(monitor, [:flush])
    end
  end

  # Drains any messages tagged with this run's ref still sitting in our
  # mailbox after a timeout-kill, so they don't accumulate across shrink
  # iterations (the worker may have queued more progress before it died).
  defp flush_ref(ref) do
    receive do
      {^ref, _, _} -> flush_ref(ref)
    after
      0 -> :ok
    end
  end

  # -- worker -----------------------------------------------------------------

  # After the run (and any teardown) finishes, forcibly stops whatever is
  # still linked to this worker (processes an implementation's init/0 started
  # with start_link and never stopped) and waits for confirmation that each
  # one has actually exited, before this worker reports :done.
  #
  # This matters because exit-signal propagation from a dying process to its
  # links is asynchronous relative to that process's own death: the parent
  # (the test process) only monitors this worker, not its children, so by the
  # time the parent sees *this* worker's :DOWN, a child (e.g. a named Agent)
  # may not have processed its exit signal yet. Trapping exits here lets this
  # worker itself wait for each child's `:EXIT` before signaling completion,
  # so a name like `Outlaw.Fixtures.NamedCounter` is guaranteed free before
  # the next run's init/0 tries to reuse it.
  defp stop_linked_children(timeout) do
    Process.flag(:trap_exit, true)

    pids =
      case Process.info(self(), :links) do
        {:links, links} -> Enum.filter(links, &is_pid/1)
        nil -> []
      end

    Enum.each(pids, &Process.exit(&1, :shutdown))
    await_children_exit(pids, timeout)
  end

  defp await_children_exit([], _timeout), do: :ok

  defp await_children_exit(pids, timeout) do
    receive do
      {:EXIT, pid, _reason} -> await_children_exit(List.delete(pids, pid), timeout)
    after
      timeout -> :ok
    end
  end

  defp execute(m, graph, observe, internal, fair_internal, steps, notify, settle_timeout) do
    w = %{
      m: m,
      graph: graph,
      observe: observe,
      internal: internal,
      fair: fair_internal,
      notify: notify,
      settle_timeout: settle_timeout
    }

    ctx = init_ctx(m, notify)
    p0 = project(m, ctx, observe, notify)
    initial = StateGraph.initial_states(graph)
    closed_initial = Walk.closure(graph, initial, internal)
    allowed = closed_initial |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
    candidates = Enum.filter(closed_initial, &(observed(graph, &1, observe) == p0))

    notify.(
      {:step,
       %Step{index: 0, outcome: :ok, projection: p0, candidates: candidates, allowed: allowed}}
    )

    {result, ctx} =
      if candidates == [] do
        {{:fail, :init_mismatch, %{}}, ctx}
      else
        case walk(w, steps, 1, ctx, candidates) do
          {:ok, ctx2, next_i, candidates_at_end} when internal != [] ->
            # End-of-run settle (§5 step 4), the same function as a mid-run
            # `:settle` point.
            with {:ok, ctx3, _settled} <- settle(w, ctx2, next_i, candidates_at_end),
                 do: {:ok, ctx3}

          {res, ctx2, _i, _candidates} ->
            {res, ctx2}
        end
      end

    if function_exported?(m, :teardown, 1) do
      # Deliberately not `call/3`: teardown runs after the pass/fail verdict
      # is already decided, so it must never become the reported `details.during`
      # for a spec-level failure. `:teardown_started` still resets `await`'s
      # per-receive timeout window (in case teardown itself hangs) without
      # being treated as a `during` label.
      notify.(:teardown_started)
      m.teardown(ctx)
    end

    result
  rescue
    e -> {:fail, :exception, %{exception: Exception.format(:error, e, __STACKTRACE__)}}
  catch
    {:outlaw_fail, kind, details} -> {:fail, kind, details}
  end

  defp init_ctx(m, notify) do
    case call(notify, "init/0", fn -> m.init() end) do
      {:ok, ctx} ->
        ctx

      other ->
        throw(
          {:outlaw_fail, :invalid_action_result,
           %{
             got: inspect(other),
             message: "init/0 must return {:ok, ctx}, got: #{inspect(other)}"
           }}
        )
    end
  end

  defp walk(_w, [], i, ctx, candidates), do: {:ok, ctx, i, candidates}

  # A mid-run `:settle` point (design spec §5 step 3): with no fair internal
  # action declared it is a no-op -- no step recorded, index not advanced.
  defp walk(%{fair: []} = w, [:settle | rest], i, ctx, candidates),
    do: walk(w, rest, i, ctx, candidates)

  defp walk(w, [:settle | rest], i, ctx, candidates) do
    case settle(w, ctx, i, candidates) do
      {:ok, ctx, settled} -> walk(w, rest, i + 1, ctx, settled)
      {fail, ctx} -> {fail, ctx, i, []}
    end
  end

  defp walk(w, [{name, params} | rest], i, ctx, candidates) do
    %{m: m, graph: graph, observe: observe, internal: internal, notify: notify} = w
    closed = Walk.closure(graph, candidates, internal)
    succ = closed |> Enum.flat_map(&StateGraph.successors(graph, &1, name)) |> Enum.uniq()

    case call(notify, "action/3 #{name} #{inspect(params)}", fn -> m.action(name, params, ctx) end) do
      {:ok, ctx} ->
        p2 = project(m, ctx, observe, notify)
        closed_succ = Walk.closure(graph, succ, internal)
        allowed = closed_succ |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
        next = Enum.filter(closed_succ, &(observed(graph, &1, observe) == p2))

        notify.(
          {:step,
           %Step{
             index: i,
             action: name,
             params: params,
             outcome: :ok,
             projection: p2,
             candidates: next,
             allowed: allowed
           }}
        )

        cond do
          succ == [] -> {{:fail, :action_not_enabled, %{}}, ctx, i, []}
          next == [] -> {{:fail, :illegal_transition, %{}}, ctx, i, []}
          true -> walk(w, rest, i + 1, ctx, next)
        end

      {:rejected, reason, ctx} ->
        p2 = project(m, ctx, observe, notify)
        allowed = closed |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
        next = Enum.filter(closed, &(observed(graph, &1, observe) == p2))

        notify.(
          {:step,
           %Step{
             index: i,
             action: name,
             params: params,
             outcome: {:rejected, reason},
             projection: p2,
             candidates: next,
             allowed: allowed
           }}
        )

        if next == [],
          do: {{:fail, :rejected_with_side_effect, %{}}, ctx, i, []},
          else: walk(w, rest, i + 1, ctx, next)

      other ->
        throw({:outlaw_fail, :invalid_action_result, %{got: inspect(other)}})
    end
  end

  defp call(notify, label, fun) do
    notify.({:started, label})
    fun.()
  end

  defp project(m, ctx, observe, notify, label \\ "project/1") do
    projection = call(notify, label, fn -> m.project(ctx) end)
    got = if is_map(projection), do: projection |> Map.keys() |> Enum.sort(), else: projection
    expected = Enum.sort(observe)

    cond do
      got != expected ->
        throw({:outlaw_fail, :invalid_projection, %{got: got, expected: expected}})

      (bad = first_invalid_entry(projection)) != nil ->
        {var, value} = bad

        throw(
          {:outlaw_fail, :invalid_projection,
           %{variable: var, value: value, message: invalid_value_hint(var, value)}}
        )

      true ->
        projection
    end
  end

  defp first_invalid_entry(projection) when is_map(projection) do
    Enum.find_value(projection, fn {var, value} ->
      case Value.invalid_leaf(value) do
        {:invalid, bad} -> {var, bad}
        nil -> nil
      end
    end)
  end

  defp first_invalid_entry(_projection), do: nil

  defp invalid_value_hint(var, value) do
    "value for #{inspect(var)} is #{inspect(value)} (#{Value.type_name(value)}); " <>
      "use strings, model/1 for model values, or set/1 for sets"
  end

  defp observed(graph, id, observe), do: graph |> StateGraph.state(id) |> Map.take(observe)

  # -- internal actions / settle (Outlaw design spec §4.3, §5) -----------------

  # `closure` (every state reachable through internal-action edges) is
  # `Walk.closure/3` -- one implementation shared with the generator.

  # An internal action is "enabled" at a state for settling purposes if it has
  # at least one successor other than the state itself: a pure self-loop can't
  # be observed, so it never blocks settling (Outlaw design spec §4.3). This
  # is checked against `fair` (the declared internal actions the *spec* marks
  # fair, via `Outlaw.Spec.fair_actions/1`), not every declared internal
  # action: an internal action the spec never requires to happen (no
  # WF_/SF_(...) naming it) is never required to happen here either.
  defp internal_enabled?(graph, state_id, name),
    do: graph |> StateGraph.successors(state_id, name) |> Enum.any?(&(&1 != state_id))

  defp settled_state?(graph, state_id, fair),
    do: Enum.all?(fair, &(not internal_enabled?(graph, state_id, &1)))

  defp pending_internal(graph, states, fair),
    do: Enum.filter(fair, fn name -> Enum.any?(states, &internal_enabled?(graph, &1, name)) end)

  # Settles at step `index`, both at the end of a run and at a mid-run
  # `:settle` point (one implementation for both). Re-projects every 10ms
  # until the implementation reaches a candidate state with no *fair*
  # internal action enabled (weak/strong fairness, bounded at runtime) --
  # `{:ok, ctx, candidates}`, the candidates matching the settled projection
  # (also recorded on the `(settle)` step) -- or fails with `{fail, ctx}`:
  # `:illegal_transition` if the projection leaves closure(candidates)
  # entirely -- checked even when no internal action is fair -- or
  # `:internal_action_stalled` if settle_timeout elapses first. `closure`
  # itself (via `internal`) always considers every declared internal action,
  # fair or not; only the quiescence check is narrowed to `fair`. Records
  # exactly one `(settle)` step either way; failure details carry
  # `during: "settle"` explicitly, since recording that step clears the
  # in-flight `during` label in `await/3`.
  defp settle(w, ctx, index, candidates) do
    deadline = System.monotonic_time(:millisecond) + w.settle_timeout
    settle_loop(w, ctx, index, candidates, deadline)
  end

  defp settle_loop(w, ctx, index, candidates, deadline) do
    %{m: m, graph: graph, observe: observe, internal: internal, fair: fair, notify: notify} = w
    p_now = project(m, ctx, observe, notify, "settle")
    closed = Walk.closure(graph, candidates, internal)
    allowed = closed |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
    c_now = Enum.filter(closed, &(observed(graph, &1, observe) == p_now))

    step = %Step{
      index: index,
      action: "(settle)",
      params: nil,
      outcome: :ok,
      projection: p_now,
      candidates: c_now,
      allowed: allowed
    }

    cond do
      c_now == [] ->
        notify.({:step, step})
        {{:fail, :illegal_transition, %{during: "settle"}}, ctx}

      Enum.any?(c_now, &settled_state?(graph, &1, fair)) ->
        notify.({:step, step})
        {:ok, ctx, c_now}

      System.monotonic_time(:millisecond) >= deadline ->
        notify.({:step, step})
        pending = pending_internal(graph, c_now, fair)

        {{:fail, :internal_action_stalled,
          %{pending: pending, settle_timeout: w.settle_timeout, during: "settle"}}, ctx}

      true ->
        Process.sleep(10)
        settle_loop(w, ctx, index, c_now, deadline)
    end
  end
end
