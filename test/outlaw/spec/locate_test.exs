defmodule Outlaw.Spec.LocateTest do
  use ExUnit.Case, async: true

  alias Outlaw.Spec.Locate

  defp read!(path), do: File.read!(path)

  describe "definition/2" do
    test "Counter Inc: a two-conjunct /\\ list with a guard and an effect" do
      text = read!("test/fixtures/specs/Counter.tla")

      assert %{
               name: "Inc",
               line: 10,
               column: 1,
               end_line: 11,
               conjuncts: [guard, effect]
             } = Locate.definition(text, "Inc")

      assert guard.kind == :guard
      assert guard.line == 10
      assert guard.column == 8
      assert guard.end_line == 10
      assert guard.end_column == 18
      assert guard.text == "/\\ x < Max"
      assert guard.expr_line == 10
      assert guard.expr_column == 11

      assert effect.kind == :effect
      assert effect.line == 11
      assert effect.column == 8
      assert effect.end_line == 11
      assert effect.end_column == 21
      assert effect.text == "/\\ x' = x + 1"
      assert effect.expr_line == 11
      assert effect.expr_column == 11
    end

    test "a conjunct's expr_column skips past the /\\ and any extra whitespace after it" do
      text = """
      ---- MODULE X ----
      Foo == /\\   padded = 1
             /\\ normal = 2
      ====
      """

      assert %{conjuncts: [padded, normal]} = Locate.definition(text, "Foo")
      # column 8 ("/\\"), then 3 extra spaces before "padded" at column 13.
      assert padded.column == 8
      assert padded.expr_column == 13
      assert normal.column == 8
      assert normal.expr_column == 11
    end

    test "Counter Reset: single-line body with no /\\ list has no conjuncts" do
      text = read!("test/fixtures/specs/Counter.tla")

      assert Locate.definition(text, "Reset") == %{
               name: "Reset",
               line: 13,
               column: 1,
               end_line: 13,
               conjuncts: []
             }
    end

    test "Bank Withdraw(a): a parameterized definition with a guard and two effects" do
      text = read!("test/fixtures/specs/Bank.tla")

      assert %{name: "Withdraw", line: 15, column: 1, end_line: 17, conjuncts: conjuncts} =
               Locate.definition(text, "Withdraw")

      assert [guard, effect1, effect2] = conjuncts
      assert guard.kind == :guard
      assert guard.text == "/\\ a <= balance"
      assert effect1.kind == :effect
      assert effect1.text == "/\\ balance' = balance - a"
      assert effect2.kind == :effect
      assert effect2.text == "/\\ lastOp' = \"withdraw\""
    end

    test "Workflow Pay(u): an EXCEPT effect among guards" do
      text = read!("test/fixtures/specs/Workflow.tla")

      assert %{name: "Pay", line: 11, column: 1, end_line: 14, conjuncts: conjuncts} =
               Locate.definition(text, "Pay")

      assert [g1, g2, effect, g3] = conjuncts
      assert g1.kind == :guard
      assert g1.text == "/\\ status[u] = \"cart\""
      assert g2.kind == :guard
      assert g2.text == "/\\ gateway = \"up\""
      assert effect.kind == :effect
      assert effect.text == "/\\ status' = [status EXCEPT ![u] = \"paid\"]"
      # UNCHANGED has no literal prime, but it is semantically an effect (it
      # constrains gateway' = gateway) -- classified as one.
      assert g3.kind == :effect
      assert g3.text == "/\\ UNCHANGED gateway"
    end

    test "TLCRunner Exit: a five-conjunct list including an IF/THEN/ELSE effect" do
      text = read!("specs/TLCRunner.tla")

      assert %{name: "Exit", line: 61, column: 1, end_line: 65, conjuncts: conjuncts} =
               Locate.definition(text, "Exit")

      assert [c1, c2, c3, c4, c5] = conjuncts
      assert c1.kind == :guard
      assert c1.text == "/\\ os = \"alive\""
      assert c2.kind == :guard
      assert c2.text == "/\\ seen <= Limit"
      assert c3.kind == :effect
      assert c3.text == "/\\ os' = \"exited\""
      assert c4.kind == :effect
      assert c4.text == "/\\ result' = IF caller = \"alive\" THEN \"ok\" ELSE result"
      assert c5.kind == :effect
      assert c5.text == "/\\ UNCHANGED <<caller, seen>>"

      for c <- conjuncts, do: assert(c.column == 9)
    end

    test "a definition name appearing only in a comment is not found" do
      text = """
      ---- MODULE X ----
      \\* Foo == 1
      Bar == 2
      ====
      """

      assert Locate.definition(text, "Foo") == nil
    end

    test "unknown name returns nil" do
      text = read!("test/fixtures/specs/Counter.tla")
      assert Locate.definition(text, "NopeNotHere") == nil
    end

    test "never raises on odd input" do
      assert Locate.definition("", "Inc") == nil
      assert Locate.definition("Inc == 1", "") == nil
    end

    test "a ' inside a string literal is not mistaken for a primed variable" do
      text = """
      ---- MODULE X ----
      Foo == /\\ msg = "don't"
             /\\ other = 1
      ====
      """

      assert %{conjuncts: [c1, c2]} = Locate.definition(text, "Foo")
      assert c1.kind == :guard
      assert c1.text == "/\\ msg = \"don't\""
      assert c2.kind == :guard
      assert c2.text == "/\\ other = 1"
    end

    test "nested (* (* *) *) block comments don't leak a name into view" do
      text = """
      ---- MODULE X ----
      (* outer (* Hidden == 1 *) still a comment *)
      Real == 2
      ====
      """

      assert Locate.definition(text, "Hidden") == nil
      assert %{name: "Real", line: 3} = Locate.definition(text, "Real")
    end

    test "an unclosed (* inside a \\* line comment doesn't blank the rest of the file" do
      text = """
      ---- MODULE X ----
      VARIABLE x
      \\* old syntax (* was used
      Tick == /\\ x' = x + 1
      Spec == WF_x(Tick)
      ====
      """

      assert %{name: "Tick", line: 4} = Locate.definition(text, "Tick")
    end

    test "LET ... IN: conjuncts come from the /\\ list after the top-level IN" do
      text =
        "---- MODULE X ----\n" <>
          "Foo == LET x == 1 IN /\\ a = 1\n" <>
          String.duplicate(" ", 21) <>
          "/\\ b' = 2\n" <>
          "====\n"

      assert %{name: "Foo", line: 2, column: 1, end_line: 3, conjuncts: [guard, effect]} =
               Locate.definition(text, "Foo")

      assert guard.kind == :guard
      assert guard.text == "/\\ a = 1"
      assert effect.kind == :effect
      assert effect.text == "/\\ b' = 2"
      assert guard.column == effect.column
    end
  end

  describe "fairness/2" do
    test "TLCRunner: WF_vars(Reap)" do
      text = read!("specs/TLCRunner.tla")

      assert Locate.fairness(text, "Reap") == %{
               line: 99,
               column: 34,
               end_column: 47,
               text: "WF_vars(Reap)"
             }
    end

    test "TLCRunner: WF_vars(LimitKill) is found independently of Reap" do
      text = read!("specs/TLCRunner.tla")

      assert %{line: 99, text: "WF_vars(LimitKill)"} = Locate.fairness(text, "LimitKill")
    end

    test "Async: WF_status(Complete)" do
      text = read!("test/fixtures/specs/Async.tla")

      assert Locate.fairness(text, "Complete") == %{
               line: 10,
               column: 36,
               end_column: 55,
               text: "WF_status(Complete)"
             }
    end

    test "a name with no WF_/SF_ occurrence returns nil" do
      text = read!("test/fixtures/specs/Counter.tla")
      assert Locate.fairness(text, "Inc") == nil
    end

    test "never raises on odd input" do
      assert Locate.fairness("", "Reap") == nil
      assert Locate.fairness("WF_vars(Reap)", "") == nil
    end

    test "nested (* (* *) *) block comments fully hide what they contain" do
      text = """
      ---- MODULE X ----
      (* outer (* WF_vars(Hidden) *) still a comment WF_vars(StillHidden) *)
      Spec == WF_vars(Real)
      ====
      """

      assert Locate.fairness(text, "Hidden") == nil
      assert Locate.fairness(text, "StillHidden") == nil

      assert Locate.fairness(text, "Real") == %{
               line: 3,
               column: 9,
               end_column: 22,
               text: "WF_vars(Real)"
             }
    end
  end
end
