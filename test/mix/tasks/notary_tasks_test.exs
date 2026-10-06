defmodule Mix.Tasks.NotaryTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tlc
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    specs = Path.join(dir, "specs")
    File.mkdir_p!(specs)

    for f <- Path.wildcard("test/fixtures/specs/*.{tla,cfg}"),
        do: File.cp!(f, Path.join(specs, Path.basename(f)))

    Application.put_env(:notary, :specs_dir, specs)
    Application.put_env(:notary, :work_dir, Path.join(dir, "work"))
    on_exit(fn -> Enum.each([:specs_dir, :work_dir], &Application.delete_env(:notary, &1)) end)
    %{specs: specs, work: Path.join(dir, "work")}
  end

  # Runs a mix task, capturing stdout and the exit code (tasks exit({:shutdown, 1}) on failure).
  defp run_task(task, args) do
    parent = self()

    output =
      capture_io(fn ->
        code =
          try do
            Mix.Task.rerun(task, args)
            0
          catch
            :exit, {:shutdown, code} -> code
          end

        send(parent, {:exit_code, code})
      end)

    assert_received {:exit_code, code}
    {output, code}
  end

  defp last_json(output),
    do: output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

  test "notary.check passes and writes report.json", %{work: work} do
    {out, 0} = run_task("notary.check", ["--json"])
    assert %{"status" => "pass", "specs" => specs} = last_json(out)
    assert Enum.map(specs, & &1["spec"]) == ["Async", "Bank", "Counter", "Wizard", "Workflow"]
    assert File.exists?(Path.join(work, "report.json"))
  end

  test "notary.check fails on bad specs with violation and spec errors" do
    Application.put_env(:notary, :specs_dir, "test/fixtures/specs_bad")
    {out, 1} = run_task("notary.check", ["--json"])
    %{"status" => "fail", "specs" => [broken, inv]} = last_json(out)

    assert [%{"stage" => "check", "status" => "error", "error" => %{"kind" => "spec_error"}}] =
             broken["stages"]

    assert [%{"stage" => "check", "status" => "fail", "violation" => %{"name" => "Small"}}] =
             inv["stages"]
  end

  test "notary.check text output" do
    {out, 0} = run_task("notary.check", ["Counter"])
    assert out =~ "Counter: pass"
    assert out =~ "all checks passed"
  end

  test "notary.test runs conformance for every discovered mapping" do
    {out, 0} = run_task("notary.test", ["--json", "--seed", "7", "--max-runs", "30"])
    %{"status" => "pass", "specs" => specs} = last_json(out)

    for spec <- specs do
      assert [
               %{"stage" => "check", "status" => "pass"},
               %{"stage" => "conformance", "status" => "pass", "seed" => 7, "runs" => 30} = conf
             ] =
               spec["stages"]

      case spec["spec"] do
        "Async" ->
          assert conf["internal"] == ["Complete"]
          assert conf["fair"] == ["Complete"]

        _ ->
          assert conf["internal"] == []
          assert conf["fair"] == []
      end

      assert %{
               "actions" => %{"reached" => _, "total" => _, "unreached" => _},
               "states" => %{"reached" => _, "total" => _, "unreached" => _},
               "transitions" => %{"reached" => _, "total" => _, "unreached" => _}
             } = conf["coverage"]
    end

    async_text = run_task("notary.test", ["Async", "--seed", "7", "--max-runs", "30"]) |> elem(0)
    assert async_text =~ "conformance: pass (30 runs, seed 7; internal: Complete*; * = fair)"

    assert async_text =~
             ~r/coverage: actions \d+\/\d+, observed states \d+\/\d+, transitions \d+\/\d+/
  end

  test "notary.test still reports a conformance failure when the failure artifact can't be written",
       %{specs: specs, work: work} do
    {:ok, spec} = Notary.Spec.fetch("Counter", specs)
    File.mkdir_p!(work)
    # A directory sitting where Viewer.write_failure wants to write the failure
    # term: File.write! can't write a file on top of a directory, so recording
    # the artifact raises. The conformance failure must still be reported.
    File.mkdir_p!(Path.join(work, "Counter-failure.term"))

    result =
      Notary.Verify.test_spec(spec, %{"Counter" => Notary.Fixtures.CounterBadResetSpec}, seed: 1)

    assert %{
             status: :fail,
             stages: [
               %{stage: :check, status: :pass},
               %{
                 stage: :conformance,
                 status: :fail,
                 payload: {:error, %Notary.Conformance.Failure{}}
               }
             ]
           } = result
  end

  test "notary.test reports specs with no mapping", %{specs: specs} do
    File.write!(
      Path.join(specs, "Lonely.tla"),
      File.read!(Path.join(specs, "Counter.tla"))
      |> String.replace("MODULE Counter", "MODULE Lonely")
    )

    File.cp!(Path.join(specs, "Counter.cfg"), Path.join(specs, "Lonely.cfg"))
    {out, 1} = run_task("notary.test", ["Lonely", "--json"])
    %{"specs" => [%{"stages" => [_, conf]}]} = last_json(out)
    assert conf["error"]["kind"] == "missing_mapping"
  end

  test "notary.verify requires a lock, passes after notary.lock, fails after a spec edit", %{
    specs: specs
  } do
    {out, 1} = run_task("notary.verify", ["--json", "--max-runs", "20"])
    assert %{"lock" => %{"status" => "fail"}} = last_json(out)

    {lock_out, 0} = run_task("notary.lock", [])
    assert lock_out =~ "Locked 10 spec files"

    {out, 0} = run_task("notary.verify", ["--json", "--max-runs", "20"])
    assert %{"status" => "pass", "lock" => %{"status" => "pass"}} = last_json(out)

    File.write!(
      Path.join(specs, "Counter.tla"),
      File.read!(Path.join(specs, "Counter.tla")) <> "\n\\* edited\n"
    )

    {out, 1} = run_task("notary.verify", [])
    assert out =~ "changed: Counter.tla"
    assert out =~ "do not edit specs"
  end

  test "notary.lock --json writes report.json alongside stdout", %{work: work} do
    {out, 0} = run_task("notary.lock", ["--json"])
    json = last_json(out)
    assert %{"status" => "pass", "locked" => locked} = json
    assert is_list(locked)

    report_path = Path.join(work, "report.json")
    assert File.exists?(report_path)
    assert JSON.decode!(File.read!(report_path)) == json
  end

  test "notary.lock rejects stray spec names instead of silently locking everything" do
    assert_raise Mix.Error, ~r/takes no spec names.*Counter/s, fn ->
      Mix.Task.rerun("notary.lock", ["Counter"])
    end
  end

  test "assert_conforms passes for correct mappings and raises a readable report for buggy ones" do
    assert Notary.Conformance.assert_conforms(Notary.Fixtures.CounterSpec, max_runs: 30) == :ok

    error =
      assert_raise Notary.Error, fn ->
        Notary.Conformance.assert_conforms(Notary.Fixtures.CounterNoGuardSpec, seed: 3)
      end

    assert error.kind == :conformance_failed
    assert error.message =~ "action_not_enabled"
    assert error.message =~ "<-- diverges here"
  end
end
