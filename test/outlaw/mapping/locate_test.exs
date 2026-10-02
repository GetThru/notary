defmodule Outlaw.Mapping.LocateTest do
  use ExUnit.Case, async: true

  alias Outlaw.Mapping.Locate

  test "CounterSpec: a multi-clause action/3 with two string-literal clauses" do
    assert %{
             file: file,
             use_line: 3,
             init_line: 7,
             actions_line: 10,
             project_line: 26,
             action_lines: %{"Inc" => 13, "Reset" => 20}
           } = Locate.locate(Outlaw.Fixtures.CounterSpec)

    assert String.ends_with?(file, "test/support/fixtures/counter_specs.ex")
  end

  test "BankOverdraftSpec: delegated callbacks give nil lines, not a crash" do
    assert %{
             use_line: 29,
             init_line: 36,
             actions_line: nil,
             project_line: nil,
             action_lines: %{}
           } = Locate.locate(Outlaw.Fixtures.BankOverdraftSpec)
  end

  test "a guarded def project/1 (when is_pid(pid)) is still found" do
    assert %{
             init_line: 7,
             actions_line: 8,
             project_line: 10,
             action_lines: %{"Inc" => 9}
           } = Locate.locate(Outlaw.Fixtures.LocateGuardedProjectSpec)
  end

  test "a guarded action/3 clause with a string-literal first argument still records its name" do
    assert %{action_lines: %{"Inc" => 21}, project_line: 22} =
             Locate.locate(Outlaw.Fixtures.LocateGuardedActionSpec)
  end

  test "a guarded action/3 catch-all clause still records \"*\"" do
    assert %{action_lines: %{"*" => 33}} =
             Locate.locate(Outlaw.Fixtures.LocateGuardedCatchAllActionSpec)
  end

  test "matches by arity, not just name: a same-named wrong-arity helper is ignored" do
    assert %{
             init_line: 47,
             actions_line: 48,
             project_line: 50,
             action_lines: %{"Inc" => 49}
           } = Locate.locate(Outlaw.Fixtures.LocateArityHelperSpec)
  end

  test "a module without source returns nil" do
    assert Locate.locate(Outlaw.Fixtures.ThisModuleDoesNotExist) == nil
  end

  test "never raises on odd input" do
    assert Locate.locate(:not_a_module_either) == nil
    assert Locate.locate("not even an atom") == nil
    assert Locate.locate(nil) == nil
  end
end
