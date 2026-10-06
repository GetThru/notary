defmodule Notary.E2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag timeout: 900_000

  setup %{tmp_dir: tmp} do
    app = Path.join(tmp, "sample_app")
    File.cp_r!("e2e/sample_app", app)
    File.rm_rf!(Path.join(app, "_build"))
    File.rm_rf!(Path.join(app, "deps"))

    env = [
      {"NOTARY_PATH", File.cwd!()},
      {"NOTARY_TLA2TOOLS", Notary.Config.jar_path()},
      {"MIX_ENV", nil}
    ]

    ctx = %{app: app, env: env}
    {_, 0} = mix(ctx, ["deps.get"])
    ctx
  end

  defp mix(ctx, args),
    do: System.cmd("mix", args, cd: ctx.app, env: ctx.env, stderr_to_stdout: true)

  defp last_json(out), do: out |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

  test "the full human + LLM workflow in a consumer project", ctx do
    {out, 0} = mix(ctx, ["notary.lock"])
    assert out =~ "Locked 2 spec files"

    {out, 0} = mix(ctx, ["notary.verify", "--json"])
    assert %{"status" => "pass"} = last_json(out)

    {out, 0} = mix(ctx, ["test"])
    assert out =~ "1 test, 0 failures"

    File.cp!(
      Path.join(ctx.app, "buggy/counter.ex"),
      Path.join(ctx.app, "lib/sample_app/counter.ex")
    )

    {out, 1} = mix(ctx, ["notary.verify", "--json"])
    %{"specs" => [%{"stages" => [_, conf]}]} = last_json(out)
    assert conf["failure"]["kind"] == "action_not_enabled"
    assert length(conf["failure"]["steps"]) == 5
    assert File.exists?(Path.join(ctx.app, "_build/notary/Counter-failure.html"))

    {out, 0} = mix(ctx, ["notary.graph", "Counter", "--trace", "failure", "--format", "mermaid"])
    assert out =~ "stateDiagram-v2"

    spec = Path.join(ctx.app, "specs/Counter.tla")
    File.write!(spec, File.read!(spec) <> "\n\\* an LLM was here\n")
    {out, 1} = mix(ctx, ["notary.verify"])
    assert out =~ "changed: Counter.tla"

    {out, 0} = mix(ctx, ["notary.new", "Thing"])
    assert out =~ "creating specs/Thing.tla"
    assert out =~ "creating specs/AGENTS.md"
    {out, 0} = mix(ctx, ["notary.check", "Thing"])
    assert out =~ "Thing: pass"
  end
end
