defmodule Outlaw.Conformance.Runner do
  @moduledoc """
  Drives an implementation through generated action sequences and checks every
  step against the spec's state graph (see the Outlaw spec §5). Each run happens
  in a fresh process, which exits with `:shutdown` afterwards so processes linked
  to it by `init/0` are cleaned up.
  """

  alias Outlaw.{Config, StateGraph}
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
        send(parent, {ref, :done, execute(module, graph, observe, steps, notify)})
        exit(:shutdown)
      end)

    await(%{ref: ref, pid: pid, monitor: monitor, timeout: timeout}, [], nil)
  end

  defp await(w, steps, during) do
    %{ref: ref, pid: pid, monitor: monitor} = w

    receive do
      {^ref, :progress, {:started, label}} ->
        await(w, steps, label)

      {^ref, :progress, {:step, step}} ->
        await(w, [step | steps], nil)

      {^ref, :done, :ok} ->
        Process.demonitor(monitor, [:flush])
        {:ok, Enum.reverse(steps)}

      {^ref, :done, {:fail, kind, details}} ->
        Process.demonitor(monitor, [:flush])
        {:error, Failure.new(kind, Enum.reverse(steps), Map.put_new(details, :during, during))}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error,
         Failure.new(:crashed, Enum.reverse(steps), %{reason: inspect(reason), during: during})}
    after
      w.timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        {:error,
         Failure.new(:timeout, Enum.reverse(steps), %{during: during, timeout: w.timeout})}
    end
  end

  # -- worker -----------------------------------------------------------------

  defp execute(m, graph, observe, steps, notify) do
    {:ok, ctx} = call(notify, "init/0", fn -> m.init() end)
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

    if function_exported?(m, :teardown, 1),
      do: call(notify, "teardown/1", fn -> m.teardown(ctx) end)

    result
  rescue
    e -> {:fail, :exception, %{exception: Exception.format(:error, e, __STACKTRACE__)}}
  catch
    {:outlaw_fail, kind, details} -> {:fail, kind, details}
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

    if got == expected,
      do: projection,
      else: throw({:outlaw_fail, :invalid_projection, %{got: got, expected: expected}})
  end

  defp observed(graph, id, observe), do: graph |> StateGraph.state(id) |> Map.take(observe)
end
