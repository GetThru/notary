defmodule Notary.DSL.GapsTest do
  @moduledoc """
  The forms the DSL cheatsheet once listed under "Known gaps": each used to
  raise or emit TLA+ that TLC can't parse.
  """
  use ExUnit.Case, async: false

  alias Notary.DSL.Description

  defmodule Gaps do
    use Notary.DSL, name: "Gaps"

    variable(flag: boolean())
    variable(n: -2..2)
    variable(step: ["a", "b"])
    variable(log: [1, 2])
    variable(r: %{ok: boolean(), count: 0..2})

    initial(flag: false, n: 0, step: "a", log: 1, r: %{ok: false, count: 0})

    action ListIn, explicit_unchanged: true do
      guard(step in ["a", "b"] and step not in ["c"] and member?(step, ["a"]))
      assign(flag: n == 0)
      unchanged([n, step])
      unchanged([:log, :r])
    end

    action Negate do
      assign(n: -n)
    end

    action Index do
      guard(at(append([1], 2), 1) == 1)
      assign(n: -1)
    end

    action Block do
      parallel do
        assign(flag: true)
        assign(step: "b")
      end
    end

    action Deposit, amount: 1..2 do
      assign(log: amount)
    end

    # Both hold, so TLC passes: Block only stops changing state once it has
    # run, and log is always 1 or 2, so one Deposit always changes it.
    property(CanBlock, do: always(enabled(Block) or (flag and step == "b")))
    property(CanDeposit, do: always(enabled(:Deposit, [1]) or enabled(:Deposit, [2])))

    fair(Deposit)

    raw(~S"""
    Twice(x) == x + x
    """)
  end

  setup_all do
    %{tla: Description.tla(Gaps.__notary_description__())}
  end

  test "a list on the right of `in` is a set", %{tla: tla} do
    assert tla =~ ~s(step \\in {"a", "b"})
    assert tla =~ ~s(step \\notin {"c"})
    assert tla =~ ~s(step \\in {"a"})
  end

  test "an assigned comparison is parenthesized", %{tla: tla} do
    assert tla =~ "flag' = (n = 0)"
  end

  test "unchanged/1 takes a list of variables or atoms", %{tla: tla} do
    assert tla =~ "UNCHANGED <<n, step>>"
    assert tla =~ "UNCHANGED <<log, r>>"
  end

  test "negative numbers pull in Integers", %{tla: tla} do
    assert tla =~ "EXTENDS Integers, Sequences\n"
    assert tla =~ "n \\in -2..2"
    assert tla =~ "n' = -n"
  end

  test "indexing a compound sequence keeps its parentheses", %{tla: tla} do
    assert tla =~ "((<<1>> \\o <<2>>)[1]) = 1"
  end

  test "parallel do-blocks conjoin their lines", %{tla: tla} do
    assert tla =~ "Block == /\\ flag' = TRUE /\\ step' = \"b\""
  end

  test "record variables get a record-set TypeOK", %{tla: tla} do
    assert tla =~ "r \\in [count: 0..2, ok: BOOLEAN]"
    assert tla =~ "r = [count |-> 0, ok |-> FALSE]"
  end

  test "enabled/1,2 render with the spec's variables", %{tla: tla} do
    assert tla =~ "ENABLED <<Block>>_<<flag, log, n, r, step>>"
    assert tla =~ "ENABLED <<Deposit(1)>>_<<flag, log, n, r, step>>"
  end

  @tag :tmp_dir
  test "fairness on a parameterized action quantifies its parameters", %{
    tla: tla,
    tmp_dir: dir
  } do
    assert tla =~ "\\A amount \\in 1..2 : WF_vars(Deposit(amount))"

    # Conformance's fairness scan still sees the action through the quantifier.
    path = Path.join(dir, "Gaps.tla")
    File.write!(path, tla)

    assert Notary.Spec.fair_actions(struct(Notary.Spec, tla_path: path)) ==
             {:ok, MapSet.new(["Deposit"])}
  end

  test "raw accepts a sigil", %{tla: tla} do
    assert tla =~ "Twice(x) == x + x"
  end

  @tag :tlc
  @tag :tmp_dir
  test "TLC parses and passes the generated spec", %{tmp_dir: dir} do
    specs = Path.join(dir, "specs")
    Application.put_env(:notary, :specs_dir, specs)
    Application.put_env(:notary, :work_dir, Path.join(dir, "work"))
    on_exit(fn -> Enum.each([:specs_dir, :work_dir], &Application.delete_env(:notary, &1)) end)

    d = Gaps.__notary_description__()
    File.mkdir_p!(specs)
    File.write!(Path.join(specs, "Gaps.tla"), Description.tla(d))
    File.write!(Path.join(specs, "Gaps.cfg"), Description.cfg(d))

    {:ok, spec} = Notary.Spec.fetch("Gaps")
    assert {:ok, _stats} = Notary.TLC.check(spec)
  end
end
