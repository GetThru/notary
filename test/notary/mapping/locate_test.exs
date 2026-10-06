defmodule Notary.Mapping.LocateTest do
  use ExUnit.Case, async: true

  alias Notary.Mapping.Locate

  test "CounterSpec: a multi-clause action/3 with two string-literal clauses" do
    assert %{
             file: file,
             use_line: 3,
             init_line: 7,
             actions_line: 10,
             project_line: 26,
             action_lines: %{"Inc" => 13, "Reset" => 20}
           } = Locate.locate(Notary.Fixtures.CounterSpec)

    assert String.ends_with?(file, "test/support/fixtures/counter_specs.ex")
  end

  test "BankOverdraftSpec: delegated callbacks give nil lines, not a crash" do
    assert %{
             use_line: 29,
             init_line: 36,
             actions_line: nil,
             project_line: nil,
             action_lines: %{}
           } = Locate.locate(Notary.Fixtures.BankOverdraftSpec)
  end

  test "a guarded def project/1 (when is_pid(pid)) is still found" do
    assert %{
             init_line: 7,
             actions_line: 8,
             project_line: 10,
             action_lines: %{"Inc" => 9}
           } = Locate.locate(Notary.Fixtures.LocateGuardedProjectSpec)
  end

  test "a guarded action/3 clause with a string-literal first argument still records its name" do
    assert %{action_lines: %{"Inc" => 21}, project_line: 22} =
             Locate.locate(Notary.Fixtures.LocateGuardedActionSpec)
  end

  test "a guarded action/3 catch-all clause still records \"*\"" do
    assert %{action_lines: %{"*" => 33}} =
             Locate.locate(Notary.Fixtures.LocateGuardedCatchAllActionSpec)
  end

  test "a \"Inc\" = name match pattern first argument records \"Inc\", not \"*\"" do
    assert %{action_lines: %{"Inc" => 45}} =
             Locate.locate(Notary.Fixtures.LocateMatchPatternActionSpec)
  end

  test "a first argument that is neither a literal name, a match pattern, nor a plain variable/_ is skipped" do
    assert Locate.locate(Notary.Fixtures.LocateSkippedPatternActionSpec).action_lines == %{}
  end

  test "matches by arity, not just name: a same-named wrong-arity helper is ignored" do
    assert %{
             init_line: 72,
             actions_line: 73,
             project_line: 75,
             action_lines: %{"Inc" => 74}
           } = Locate.locate(Notary.Fixtures.LocateArityHelperSpec)
  end

  test "a module without source returns nil" do
    assert Locate.locate(Notary.Fixtures.ThisModuleDoesNotExist) == nil
  end

  test "never raises on odd input" do
    assert Locate.locate(:not_a_module_either) == nil
    assert Locate.locate("not even an atom") == nil
    assert Locate.locate(nil) == nil
  end
end
