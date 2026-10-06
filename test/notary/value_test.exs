defmodule Notary.ValueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Notary.Value

  describe "parse/1 with real TLC output" do
    test "scalars" do
      assert Value.parse("0") == {:ok, 0}
      assert Value.parse("-3") == {:ok, -3}
      assert Value.parse("TRUE") == {:ok, true}
      assert Value.parse("FALSE") == {:ok, false}
      assert Value.parse(~S("open")) == {:ok, "open"}
      assert Value.parse("u1") == {:ok, {:model_value, "u1"}}
    end

    test "escaped strings" do
      assert Value.parse(~S("a \"q\" b")) == {:ok, ~S(a "q" b)}
      assert Value.parse(~S("back\\slash")) == {:ok, ~S(back\slash)}
      assert Value.parse(~S("line\nbreak")) == {:ok, "line\nbreak"}
    end

    test "sets and sequences" do
      assert Value.parse("{}") == {:ok, MapSet.new()}

      assert Value.parse("{u1, u2}") ==
               {:ok, MapSet.new([{:model_value, "u1"}, {:model_value, "u2"}])}

      assert Value.parse("<<>>") == {:ok, []}
      assert Value.parse("<<u2, u1>>") == {:ok, [{:model_value, "u2"}, {:model_value, "u1"}]}
      assert Value.parse("<<100, 200, 300, 400>>") == {:ok, [100, 200, 300, 400]}
      assert Value.parse("<<1, <<2>>>>") == {:ok, [1, [2]]}
    end

    test "records" do
      assert Value.parse(~S([status |-> "open", n |-> 0])) ==
               {:ok, %{"status" => "open", "n" => 0}}
    end

    test "functions" do
      assert Value.parse("(u1 :> 0 @@ u2 :> 1)") ==
               {:ok, %{{:model_value, "u1"} => 0, {:model_value, "u2"} => 1}}

      assert Value.parse("(1 :> TRUE)") == {:ok, %{1 => true}}
    end

    test "values wrapped across lines in TLC traces" do
      raw = """
      [ a |-> 1,
        bbbb |->
            { "cccc",
              "dddd" } ]
      """

      assert Value.parse(raw) == {:ok, %{"a" => 1, "bbbb" => MapSet.new(["cccc", "dddd"])}}
    end

    test "garbage is an error carrying the raw text" do
      for raw <- ["[a |-> ", "{1,", "<<1 2>>", "(1 :> )", "\"open", "1 2", "", "?"] do
        assert Value.parse(raw) == {:error, {:unparseable_value, raw}}
      end
    end
  end

  describe "to_tla/1" do
    test "prints canonical TLA+ syntax" do
      assert Value.to_tla(%{"status" => "open", "n" => 0}) == ~S([n |-> 0, status |-> "open"])
      assert Value.to_tla(%{Value.model("u1") => 0}) == "(u1 :> 0)"
      assert Value.to_tla(MapSet.new([2, 1])) == "{1, 2}"
      assert Value.to_tla([1, "x"]) == ~S(<<1, "x">>)
      assert Value.to_tla(~S(a "q")) == ~S("a \"q\"")
      assert Value.to_tla(true) == "TRUE"
      assert Value.to_tla(%{}) == "<<>>"
    end

    test "falls back to inspect/1 for values outside the representation instead of raising" do
      assert Value.to_tla(nil) == "nil"
      assert Value.to_tla(:pending) == ":pending"
      assert Value.to_tla(1.5) == "1.5"
      assert Value.to_tla({:a, :b}) == "{:a, :b}"
      assert Value.to_tla(%URI{}) == inspect(%URI{})
    end

    test "a map with atom keys does not crash (falls into the function-value branch)" do
      assert Value.to_tla(%{status: nil}) == "(:status :> nil)"
    end
  end

  property "parse(to_tla(v)) round-trips" do
    check all(value <- value_gen(), max_runs: 300) do
      assert Value.parse(Value.to_tla(value)) == {:ok, value}
    end
  end

  defp ident, do: string(?a..?z, min_length: 1, max_length: 6)

  defp value_gen do
    leaf =
      one_of([
        integer(),
        boolean(),
        string(:printable, max_length: 6),
        map(ident(), &Value.model/1)
      ])

    tree(leaf, fn child ->
      one_of([
        map(list_of(child, max_length: 3), &MapSet.new/1),
        list_of(child, max_length: 3),
        map_of(ident(), child, min_length: 1, max_length: 3),
        map_of(child, child, min_length: 1, max_length: 3)
      ])
    end)
  end
end
