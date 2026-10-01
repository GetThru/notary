defmodule Outlaw.Conformance.Runner do
  @moduledoc """
  Drives an implementation through generated action sequences and checks every
  step against the spec's state graph (see the Outlaw spec §5). Each run happens
  in a fresh process, which exits with `:shutdown` afterwards so processes linked
  to it by `init/0` are cleaned up.
  """

  alias Outlaw.{Config, StateGraph, Value}
  alias Outlaw.Conformance.{Failure, Step}

  @spec check(module(), StateGraph.t(), [String.t()], keyword()) ::
          {:ok, %{runs: non_neg_integer(), seed: integer()}} | {:error, Failure.t()}
  def check(module, graph, observe, opts) do
    seed = Keyword.get_lazy(opts, :seed, fn -> :rand.uniform(1_000_000) end)
    max_runs = Keyword.get(opts, :max_runs, Config.get(:max_runs))
    max_steps = Keyword.get(opts, :max_steps, Config.get(:max_steps))
    timeout = Keyword.get(opts, :action_timeout, Config.get(:action_timeout))

    generator = steps_generator(module.actions(), max_steps)
    options = [initial_seed: {0, 0, seed}, max_runs: max_runs, max_shrinking_steps: 500]

    result =
      StreamData.check_all(generator, options, fn steps ->
        case run(module, graph, observe, steps, timeout) do
          {:ok, _steps} -> {:ok, nil}
          {:error, failure} -> {:error, failure}
        end
      end)

    case result do
      {:ok, _} -> {:ok, %{runs: max_runs, seed: seed}}
      {:error, %{shrunk_failure: failure}} -> {:error, %{failure | seed: seed}}
    end
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

  @spec run(module(), StateGraph.t(), [String.t()], [{String.t(), map()}], timeout()) ::
          {:ok, [Step.t()]} | {:error, Failure.t()}
  def run(module, graph, observe, steps, timeout) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        notify = fn event -> send(parent, {ref, :progress, event}) end
        result = execute(module, graph, observe, steps, notify)
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

  defp execute(m, graph, observe, steps, notify) do
    ctx = init_ctx(m, notify)
    p0 = project(m, ctx, observe, notify)
    initial = StateGraph.initial_states(graph)
    allowed = initial |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
    candidates = Enum.filter(initial, &(observed(graph, &1, observe) == p0))

    notify.(
      {:step,
       %Step{index: 0, outcome: :ok, projection: p0, candidates: candidates, allowed: allowed}}
    )

    {result, ctx} =
      if candidates == [],
        do: {{:fail, :init_mismatch, %{}}, ctx},
        else: walk(m, graph, observe, steps, 1, ctx, p0, candidates, notify)

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

  defp walk(_m, _graph, _observe, [], _i, ctx, _p, _candidates, _notify), do: {:ok, ctx}

  defp walk(m, graph, observe, [{name, params} | rest], i, ctx, p, candidates, notify) do
    succ = candidates |> Enum.flat_map(&StateGraph.successors(graph, &1, name)) |> Enum.uniq()

    case call(notify, "action/3 #{name} #{inspect(params)}", fn -> m.action(name, params, ctx) end) do
      {:ok, ctx} ->
        p2 = project(m, ctx, observe, notify)
        allowed = succ |> Enum.map(&observed(graph, &1, observe)) |> Enum.uniq()
        next = Enum.filter(succ, &(observed(graph, &1, observe) == p2))

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
          succ == [] -> {{:fail, :action_not_enabled, %{}}, ctx}
          next == [] -> {{:fail, :illegal_transition, %{}}, ctx}
          true -> walk(m, graph, observe, rest, i + 1, ctx, p2, next, notify)
        end

      {:rejected, reason, ctx} ->
        p2 = project(m, ctx, observe, notify)

        notify.(
          {:step,
           %Step{
             index: i,
             action: name,
             params: params,
             outcome: {:rejected, reason},
             projection: p2,
             candidates: candidates,
             allowed: [p]
           }}
        )

        if p2 == p,
          do: walk(m, graph, observe, rest, i + 1, ctx, p, candidates, notify),
          else: {{:fail, :rejected_with_side_effect, %{}}, ctx}

      other ->
        throw({:outlaw_fail, :invalid_action_result, %{got: inspect(other)}})
    end
  end

  defp call(notify, label, fun) do
    notify.({:started, label})
    fun.()
  end

  defp project(m, ctx, observe, notify) do
    projection = call(notify, "project/1", fn -> m.project(ctx) end)
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
end
