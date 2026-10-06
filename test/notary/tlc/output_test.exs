defmodule Notary.TLC.OutputTest do
  use ExUnit.Case, async: true

  alias Notary.TLC.Output

  defp interpret(name, exit_status) do
    "test/fixtures/tlc_output/#{name}.out"
    |> File.read!()
    |> Output.items()
    |> Output.interpret(exit_status)
  end

  test "items/1 splits messages and raw text" do
    items = Output.items(File.read!("test/fixtures/tlc_output/parse_error.out"))
    assert {:message, %{code: 2220, severity: 0, body: "Starting SANY..."}} = hd(items)
    assert {:text, "***Parse Error***"} in items
  end

  test "successful run returns stats" do
    assert interpret("pass", 0) == {:ok, %{distinct_states: 10, states_generated: 14}}
  end

  test "invariant violation with trace" do
    assert {:violation, v} = interpret("invariant", 12)
    assert v.kind == :invariant
    assert v.name == "Inv"
    assert v.message == "Invariant Inv is violated."

    assert v.trace == [
             %{index: 1, action: nil, state: %{"x" => 0}},
             %{index: 2, action: "Inc", state: %{"x" => 1}},
             %{index: 3, action: "Inc", state: %{"x" => 2}}
           ]
  end

  test "deadlock" do
    assert {:violation, %{kind: :deadlock, name: nil, trace: [_, %{action: "Next"}]}} =
             interpret("deadlock", 11)
  end

  test "liveness with wrapped values, loop and stuttering" do
    assert {:violation, v} = interpret("liveness", 13)
    assert v.kind == :liveness
    assert [s1, s2, loop, stutter] = v.trace
    assert s1.state["r"]["a"] == 1
    assert s1.state["x"] == 0
    assert s2.action == "Flip"
    assert loop == %{index: 1, back_to: 1}
    assert stutter == %{index: 3, stuttering: true}
  end

  test "assertion failure" do
    assert {:violation, %{kind: :assertion, message: message, trace: [_]}} =
             interpret("assert", 14)

    assert message =~ "x too big"
  end

  test "parse error reports SANY text and location" do
    assert {:error, %Notary.Error{kind: :spec_error} = e} = interpret("parse_error", 150)
    assert e.message =~ "Bad"
    assert e.details.output =~ "***Parse Error***"
    assert e.details.location == %{module: "Bad", line: 3, column: 9}
  end

  test "semantic error reports location" do
    assert {:error, %Notary.Error{kind: :spec_error} = e} = interpret("semantic_error", 150)
    assert e.details.output =~ "Unknown operator"
    assert e.details.location == %{module: "Sem", line: 3, column: 13}
  end

  test "unknown non-zero exit is a tlc_failed error with the output tail" do
    assert {:error, %Notary.Error{kind: :tlc_failed} = e} =
             Output.interpret(Output.items("Exception in thread main\n"), 1)

    assert e.details.output =~ "Exception"
  end

  test "single-line trace step parses index and action from header" do
    output = """
    @!@!@STARTMSG 2110:1 @!@!@
    Invariant Inv is violated.
    @!@!@ENDMSG 2110 @!@!@
    @!@!@STARTMSG 2217:4 @!@!@
    2: <Inc line 6, col 8 to line 6, col 17 of module Counter>
    @!@!@ENDMSG 2217 @!@!@
    """

    assert {:violation, v} = Output.interpret(Output.items(output), 12)
    assert v.kind == :invariant
    assert v.trace == [%{index: 2, action: "Inc", state: %{}}]
  end
end
