defmodule Outlaw.Specs.TLCRunner.FakeTLC do
  @moduledoc false
  # Helpers around test/support/fake_tlc.sh, a stand-in for `java` that the
  # test (or mapping) drives through a FIFO: see that script for the protocol.

  @java Path.expand("../fake_tlc.sh", __DIR__)

  def java, do: @java

  @doc "Creates `<dir>/ctl` (a FIFO) and opens it read-write, so writes never block."
  def open!(dir) do
    ctl = Path.join(dir, "ctl")
    {_, 0} = System.cmd("mkfifo", [ctl])
    # O_RDWR on a FIFO never blocks on open, and since we are also a reader,
    # writes neither block nor raise SIGPIPE once the fake is gone.
    {:ok, fifo} = File.open(ctl, [:read, :write, :binary])
    fifo
  end

  def command(fifo, cmd), do: :ok = IO.binwrite(fifo, cmd <> "\n")

  def os_pid(dir) do
    case File.read(Path.join(dir, "pid")) do
      {:ok, text} -> text |> String.trim() |> String.to_integer()
      {:error, _} -> nil
    end
  end

  def exited?(dir), do: File.exists?(Path.join(dir, "exited"))

  def await_pid!(dir, timeout \\ 2_000) do
    case until(timeout, fn -> os_pid(dir) end) do
      nil -> raise "fake TLC in #{dir} did not write its pid within #{timeout}ms"
      pid -> pid
    end
  end

  @doc "True if the OS process exists and is not a zombie (a killed, unreaped process is dead)."
  def alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        # "pid (comm) S ..." — the state letter follows the last ')'.
        state = stat |> String.split(")") |> List.last() |> String.trim_leading()
        String.first(state) not in ["Z", "X"]

      {:error, _} ->
        if File.dir?("/proc"), do: false, else: ps_alive?(pid)
    end
  end

  defp ps_alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  def eventually_dead?(pid, timeout \\ 2_000), do: until(timeout, fn -> not alive?(pid) end)

  def kill(dir) do
    case os_pid(dir) do
      nil -> :ok
      pid -> if alive?(pid), do: System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  @doc "Polls `fun` every 2ms until it returns a truthy value or `timeout` ms pass; returns the last value."
  def until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(deadline, fun)
  end

  defp poll(deadline, fun) do
    value = fun.()

    if value || System.monotonic_time(:millisecond) >= deadline do
      value
    else
      Process.sleep(2)
      poll(deadline, fun)
    end
  end
end

defmodule Outlaw.Specs.TLCRunner do
  @moduledoc false
  # Conformance mapping for specs/TLCRunner.tla (human-authored): Outlaw
  # verifying its own TLC runner. The OS process is test/support/fake_tlc.sh,
  # driven through a FIFO; the "caller" is a plain unlinked process that
  # starts the run, awaits it and records the result.
  #
  # External spec actions (Start, Progress, Exit, Timeout, Cancel, CallerDies)
  # are driven here; LimitKill (the runner's state limit) and Reap (the
  # watchdog) are internal — the runner does them on its own.
  #
  # Every guard is checked against the current projection before any side
  # effect, so a rejected action never changes anything.
  use Outlaw.Conformance, spec: "specs/TLCRunner.tla", internal: ["LimitKill", "Reap"]

  alias Outlaw.Specs.TLCRunner.FakeTLC
  alias Outlaw.Tools.TLCRunner

  # Must match `CONSTANT Limit = 2` in specs/TLCRunner.cfg: TLC checks the
  # spec's `Limit` against this same value, so the two must stay in sync.
  @limit 2
  @wait 2_000
  # How long project/1 waits for the result to catch up with the OS process,
  # and for a SIGKILLed process to stop looking alive (see `snapshot/1`).
  @reply_wait 1_000
  @kill_wait 100

  @impl true
  def init do
    dir =
      Path.join([
        Outlaw.Config.work_dir(),
        "tmp",
        "fake-tlc-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    fifo = FakeTLC.open!(dir)
    {:ok, agent} = Agent.start_link(fn -> %{seen: 0, result: :none, caller_killed: false} end)
    mapping = self()
    caller = spawn(fn -> caller_loop(mapping, agent, dir) end)
    {:ok, %{dir: dir, fifo: fifo, agent: agent, caller: caller, run: nil}}
  end

  # The process that "called run/2": starts the run, hands the Run back to
  # the mapping, awaits the result and records it — unless CallerDies already
  # decided it never sees one — then stays alive. Unlinked (a link would make
  # the mapping process part of the spec's "caller"), but it monitors the
  # mapping process and exits when that goes down (e.g. the conformance worker
  # killed on action_timeout), so it never leaks; the runner's watchdog then
  # cleans up the fake.
  defp caller_loop(mapping, agent, dir) do
    mon = Process.monitor(mapping)

    receive do
      {:DOWN, ^mon, :process, _, _} ->
        :ok

      {:start, args} ->
        {:ok, run} =
          TLCRunner.start(args,
            java: FakeTLC.java(),
            jar: "unused",
            timeout: :infinity,
            max_states: @limit,
            cd: dir
          )

        send(mapping, {:run, self(), run})

        with {:ok, reply} <- await_unless_down(run, mon) do
          result = result_name(reply)

          Agent.update(agent, fn
            %{caller_killed: true} = st -> st
            st -> %{st | result: result}
          end)

          receive do
            {:DOWN, ^mon, :process, _, _} -> :ok
          end
        end
    end
  end

  # TLCRunner.await/2 in short slices, so the mapping's :DOWN is noticed.
  defp await_unless_down(run, mon) do
    case TLCRunner.await(run, 50) do
      {:error, %{kind: :await_timeout}} ->
        receive do
          {:DOWN, ^mon, :process, _, _} -> :mapping_down
        after
          0 -> await_unless_down(run, mon)
        end

      reply ->
        {:ok, reply}
    end
  end

  defp result_name({:ok, _}), do: "ok"
  defp result_name({:error, %{kind: :tlc_timeout}}), do: "timeout"
  defp result_name({:error, %{kind: :too_many_states}}), do: "too_many_states"
  defp result_name({:error, %{kind: :tlc_cancelled}}), do: "cancelled"
  # Anything else (e.g. :tlc_crashed) is not a spec value and fails the check.
  defp result_name({:error, %{kind: kind}}), do: Atom.to_string(kind)

  @impl true
  def actions do
    for name <- ~w(Start Progress Exit Timeout Cancel CallerDies), into: %{} do
      {name, StreamData.constant(%{})}
    end
  end

  @impl true
  def action(name, _params, ctx) do
    s = snapshot(ctx)

    case guard(name, s) do
      :ok -> perform(name, s, ctx)
      {:error, reason} -> {:rejected, reason, ctx}
    end
  end

  defp guard("Start", s), do: allow(s.os == "none" and s.caller == "alive", :not_startable)

  defp guard(name, s) when name in ["Progress", "Exit"],
    do: allow(s.os == "alive" and s.seen <= @limit, :not_running_or_over_limit)

  defp guard(name, s) when name in ["Timeout", "Cancel"],
    do: allow(s.os == "alive" and s.caller == "alive", :not_running)

  defp guard("CallerDies", s),
    do: allow(s.caller == "alive" and s.result == "none", :caller_gone_or_done)

  defp allow(true, _reason), do: :ok
  defp allow(false, reason), do: {:error, reason}

  defp perform("Start", _s, ctx) do
    send(ctx.caller, {:start, [ctx.dir]})
    caller = ctx.caller

    receive do
      {:run, ^caller, run} ->
        _ = FakeTLC.until(@wait, fn -> FakeTLC.os_pid(ctx.dir) end)
        {:ok, %{ctx | run: run}}
    after
      @wait -> {:ok, ctx}
    end
  end

  defp perform("Progress", _s, ctx) do
    Agent.update(ctx.agent, &%{&1 | seen: &1.seen + 1})
    FakeTLC.command(ctx.fifo, "progress")
    {:ok, ctx}
  end

  defp perform("Exit", s, ctx) do
    FakeTLC.command(ctx.fifo, "exit")

    # Done when the fake has exited and (if the caller is alive) the result is
    # in; or the watchdog (Reap) killed the fake before it read "exit".
    FakeTLC.until(@wait, fn ->
      now = snapshot(ctx)
      now.os == "killed" or (now.os == "exited" and (s.caller == "dead" or now.result != "none"))
    end)

    if snapshot(ctx).os == "killed",
      do: {:rejected, :killed_before_exit, ctx},
      else: {:ok, ctx}
  end

  defp perform("Timeout", _s, ctx) do
    TLCRunner.__expire__(ctx.run)
    await_result(ctx, "timeout")
  end

  defp perform("Cancel", _s, ctx) do
    TLCRunner.cancel(ctx.run)
    await_result(ctx, "cancelled")
  end

  defp perform("CallerDies", _s, ctx) do
    # Decided inside the Agent, so the caller can't record a result after we
    # chose to kill it (the spec's CallerDies requires result = "none").
    killed? =
      Agent.get_and_update(ctx.agent, fn
        %{result: :none} = st ->
          Process.exit(ctx.caller, :kill)
          {true, %{st | caller_killed: true}}

        st ->
          {false, st}
      end)

    if killed? do
      FakeTLC.until(@wait, fn -> not Process.alive?(ctx.caller) end)
      {:ok, ctx}
    else
      {:rejected, :result_already_returned, ctx}
    end
  end

  # Waits for the result. The only legitimate lost race is LimitKill winning
  # (the runner read an over-limit line from a just-sent Progress first): then
  # this action had no effect. Anything else — no result at all, or an
  # unexpected one — is reported as {:ok, ctx}, so the projection exposes the
  # divergence (the conformance runner checks a rejection's projection only
  # against the closure, so rejecting here would hide e.g. an ignored cancel).
  defp await_result(ctx, expected) do
    FakeTLC.until(@wait, fn -> snapshot(ctx).result != "none" end)

    case snapshot(ctx).result do
      "too_many_states" when expected != "too_many_states" ->
        {:rejected, :limit_kill_won, ctx}

      _ ->
        {:ok, ctx}
    end
  end

  @impl true
  def project(ctx), do: ctx |> snapshot() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

  # The spec changes `os` and `result` in one step (LimitKill, Exit, Timeout,
  # Cancel); the implementation does it in two (the runner kills / sees the
  # exit, then the caller records the reply). Two such gaps are bridged, each
  # with a bound, after which the raw state is reported (so a real bug, e.g.
  # no reply ever, still shows):
  #   * caller alive, process stopped, no result yet: the reply is in flight
  #     (up to @reply_wait);
  #   * a kill result (timeout/cancelled/too_many_states) while the process
  #     still looks alive: SIGKILL latency (up to @kill_wait).
  # "ok" while the process looks alive is never bridged: the fake writes its
  # exited marker before exiting, so that state is a real divergence.
  defp snapshot(ctx), do: snapshot(ctx, System.monotonic_time(:millisecond))

  defp snapshot(ctx, started) do
    s = raw_snapshot(ctx)

    case gap_bound(s) do
      nil ->
        s

      bound ->
        if System.monotonic_time(:millisecond) - started >= bound do
          s
        else
          Process.sleep(2)
          snapshot(ctx, started)
        end
    end
  end

  defp gap_bound(%{caller: "alive", os: os, result: "none"}) when os in ["exited", "killed"],
    do: @reply_wait

  defp gap_bound(%{os: "alive", result: result})
       when result in ["timeout", "cancelled", "too_many_states"],
       do: @kill_wait

  defp gap_bound(_), do: nil

  defp raw_snapshot(ctx) do
    %{seen: seen, result: result} = Agent.get(ctx.agent, & &1)

    %{
      os: os_state(ctx.dir),
      caller: if(Process.alive?(ctx.caller), do: "alive", else: "dead"),
      seen: seen,
      result: if(result == :none, do: "none", else: result)
    }
  end

  defp os_state(dir) do
    case FakeTLC.os_pid(dir) do
      nil ->
        "none"

      pid ->
        cond do
          FakeTLC.exited?(dir) -> "exited"
          FakeTLC.alive?(pid) -> "alive"
          true -> "killed"
        end
    end
  end

  @impl true
  def teardown(ctx) do
    Process.exit(ctx.caller, :kill)
    FakeTLC.kill(ctx.dir)
    File.close(ctx.fifo)
    File.rm_rf(ctx.dir)
  end
end
