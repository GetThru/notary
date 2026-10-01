defmodule Outlaw.ScaffoldTest do
  use ExUnit.Case, async: false

  alias Outlaw.Scaffold

  @moduletag :tmp_dir

  defp files(opts \\ []), do: Scaffold.files("CheckoutFlow", Keyword.merge([specs_dir: "specs", app_module: "MyApp"], opts))

  test "generates spec, cfg, AGENTS.md, mapping and test" do
    paths = Enum.map(files(), &elem(&1, 0))

    assert paths == [
             "specs/CheckoutFlow.tla",
             "specs/CheckoutFlow.cfg",
             "specs/AGENTS.md",
             "test/outlaw/checkout_flow_spec.ex",
             "test/outlaw/checkout_flow_conformance_test.exs"
           ]

    contents = Map.new(files(), fn {path, content, _} -> {path, content} end)
    assert contents["specs/CheckoutFlow.tla"] =~ "MODULE CheckoutFlow"
    assert contents["test/outlaw/checkout_flow_spec.ex"] =~ "defmodule MyApp.Specs.CheckoutFlow do"
    assert contents["test/outlaw/checkout_flow_spec.ex"] =~ ~s(spec: "specs/CheckoutFlow.tla")
    assert contents["specs/AGENTS.md"] =~ "Never edit"
    assert {:ok, _} = Code.string_to_quoted(contents["test/outlaw/checkout_flow_spec.ex"])
    assert {:ok, _} = Code.string_to_quoted(contents["test/outlaw/checkout_flow_conformance_test.exs"])
  end

  test "--no-mapping generates only spec files" do
    assert Enum.map(files(mapping: false), &elem(&1, 0)) ==
             ["specs/CheckoutFlow.tla", "specs/CheckoutFlow.cfg", "specs/AGENTS.md"]
  end

  test "write refuses to overwrite, but leaves an existing AGENTS.md alone", %{tmp_dir: root} do
    assert {:ok, written} = Scaffold.write(files(), root)
    assert length(written) == 5
    assert {:error, ["specs/CheckoutFlow.tla" | _]} = Scaffold.write(files(), root)

    File.write!(Path.join(root, "specs/AGENTS.md"), "custom")
    other = Scaffold.files("Other", specs_dir: "specs", app_module: "MyApp")
    assert {:ok, written} = Scaffold.write(other, root)
    refute "specs/AGENTS.md" in written
    assert File.read!(Path.join(root, "specs/AGENTS.md")) == "custom"
  end

  test "next_steps mentions mix.exs setup, the CLAUDE.md snippet and the lock" do
    text = Scaffold.next_steps("CheckoutFlow", true)
    assert text =~ ~s(preferred_envs: ["outlaw.test": :test, "outlaw.verify": :test])
    assert text =~ ~s("test/outlaw")
    assert text =~ "specs/AGENTS.md"
    assert text =~ "mix outlaw.lock"
  end

  @tag :tlc
  test "the generated spec passes TLC", %{tmp_dir: root} do
    Application.put_env(:outlaw, :work_dir, Path.join(root, "work"))
    on_exit(fn -> Application.delete_env(:outlaw, :work_dir) end)
    {:ok, _} = Scaffold.write(files(mapping: false), root)
    {:ok, spec} = Outlaw.Spec.fetch("CheckoutFlow", Path.join(root, "specs"))
    assert {:ok, %{distinct_states: 4}} = Outlaw.TLC.check(spec)
  end
end
