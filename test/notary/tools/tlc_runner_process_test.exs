defmodule Notary.Tools.TLCRunnerProcessTest do
  # Drives Notary.Tools.TLCRunner against test/support/fake_tlc.sh (no JVM).
  use ExUnit.Case, async: true

  alias Notary.Error
  alias Notary.Specs.TLCRunner.FakeTLC
  alias Notary.Tools.TLCRunner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    fifo = FakeTLC.open!(dir)
    on_exit(fn -> FakeTLC.kill(dir) end)
    %{dir: dir, fifo: fifo}
  end

  defp start(dir, opts \\ []) do
    opts =
      Keyword.merge(
        [java: FakeTLC.java(), jar: "unused", timeout: :infinity, max_states: 2],
        opts
      )

    {:ok, run} = TLCRunner.start([dir], opts)
    os_pid = FakeTLC.await_pid!(dir)
    {run, os_pid}
  end

  test "start then the process exits on its own: {:ok, exit_status 0} with output", ctx do
    {run, _os_pid} = start(ctx.dir)
    assert %TLCRunner.Run{owner: owner} = run
    assert owner == self()

    FakeTLC.command(ctx.fifo, "progress")
    FakeTLC.command(ctx.fifo, "exit")

    assert {:ok, %{exit_status: 0, output: output}} = TLCRunner.await(run, 2_000)
    assert output =~ "1 distinct states found"
    assert File.exists?(Path.join(ctx.dir, "exited"))
  end

  test "cancel kills the OS process and await returns :tlc_cancelled", ctx do
    {run, os_pid} = start(ctx.dir)

    assert :ok = TLCRunner.cancel(run)
    assert {:error, %Error{kind: :tlc_cancelled}} = TLCRunner.await(run, 2_000)
    assert FakeTLC.eventually_dead?(os_pid)
    refute File.exists?(Path.join(ctx.dir, "exited"))
  end

  test "cancel from another process works, and cancelling a finished run is a no-op", ctx do
    {run, _os_pid} = start(ctx.dir)

    Task.async(fn -> TLCRunner.cancel(run) end) |> Task.await()
    assert {:error, %Error{kind: :tlc_cancelled}} = TLCRunner.await(run, 2_000)
    assert :ok = TLCRunner.cancel(run)
  end

  test "__expire__ (the deadline) kills the OS process and returns :tlc_timeout", ctx do
    {run, os_pid} = start(ctx.dir)

    TLCRunner.__expire__(run)

    assert {:error, %Error{kind: :tlc_timeout, details: %{output_tail: _}}} =
             TLCRunner.await(run, 2_000)

    assert FakeTLC.eventually_dead?(os_pid)
  end

  test "a real timeout option expires on its own", ctx do
    {run, os_pid} = start(ctx.dir, timeout: 50)

    assert {:error, %Error{kind: :tlc_timeout, message: message}} = TLCRunner.await(run, 2_000)
    assert message =~ "within 50ms"
    assert FakeTLC.eventually_dead?(os_pid)
  end

  test "progress past max_states kills the OS process: :too_many_states", ctx do
    {run, os_pid} = start(ctx.dir)

    for _ <- 1..3, do: FakeTLC.command(ctx.fifo, "progress")

    assert {:error, %Error{kind: :too_many_states, details: %{distinct_states: 3}}} =
             TLCRunner.await(run, 2_000)

    assert FakeTLC.eventually_dead?(os_pid)
  end

  test "killing the owner kills the OS process (watchdog)", ctx do
    test = self()

    owner =
      spawn(fn ->
        {:ok, run} =
          TLCRunner.start([ctx.dir],
            java: FakeTLC.java(),
            jar: "unused",
            timeout: :infinity,
            max_states: 2
          )

        send(test, {:run, run})
        TLCRunner.await(run)
      end)

    assert_receive {:run, run}, 2_000
    os_pid = FakeTLC.await_pid!(ctx.dir)
    assert FakeTLC.alive?(os_pid)

    runner_ref = Process.monitor(run.pid)
    Process.exit(owner, :kill)

    assert FakeTLC.eventually_dead?(os_pid)
    assert_receive {:DOWN, ^runner_ref, :process, _, _}, 2_000
  end

  test "the runner is not linked to the owner", ctx do
    {run, _os_pid} = start(ctx.dir)
    {:links, links} = Process.info(self(), :links)
    refute run.pid in links
    TLCRunner.cancel(run)
    TLCRunner.await(run, 2_000)
  end

  test "await returns :tlc_crashed if the runner dies without replying", ctx do
    {run, _os_pid} = start(ctx.dir)
    Process.exit(run.pid, :kill)
    assert {:error, %Error{kind: :tlc_crashed}} = TLCRunner.await(run, 2_000)
  end

  test "run/2 is start + await", ctx do
    task =
      Task.async(fn ->
        TLCRunner.run([ctx.dir],
          java: FakeTLC.java(),
          jar: "unused",
          timeout: :infinity,
          max_states: 2
        )
      end)

    _ = FakeTLC.await_pid!(ctx.dir)
    FakeTLC.command(ctx.fifo, "exit")
    assert {:ok, %{exit_status: 0}} = Task.await(task)
  end
end
