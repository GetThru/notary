defmodule Outlaw.SpecTest do
  use ExUnit.Case, async: true

  alias Outlaw.Spec

  @moduletag :tmp_dir

  defp write(dir, files),
    do: Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)

  test "discovers specs that have a .cfg, sorted", %{tmp_dir: dir} do
    write(dir, [{"B.tla", "b"}, {"B.cfg", ""}, {"A.tla", "a"}, {"A.cfg", ""}, {"Helper.tla", "h"}])

    assert [%Spec{name: "A"} = a, %Spec{name: "B"}] = Spec.discover(dir)
    assert a.tla_path == Path.join(dir, "A.tla")
    assert a.cfg_path == Path.join(dir, "A.cfg")
    assert a.dir == dir
  end

  test "fetch and select", %{tmp_dir: dir} do
    write(dir, [{"A.tla", "a"}, {"A.cfg", ""}, {"B.tla", "b"}, {"B.cfg", ""}])
    assert {:ok, %Spec{name: "A"}} = Spec.fetch("A", dir)
    assert {:error, %Outlaw.Error{kind: :unknown_spec}} = Spec.fetch("Nope", dir)
    assert {:ok, [_, _]} = Spec.select([], dir)
    assert {:ok, [%Spec{name: "B"}]} = Spec.select(["B"], dir)
    assert {:error, %Outlaw.Error{kind: :unknown_spec}} = Spec.select(["B", "Nope"], dir)
  end

  test "from_path derives the cfg", %{tmp_dir: dir} do
    spec = Spec.from_path(Path.join(dir, "Bank.tla"))
    assert spec.name == "Bank"
    assert spec.cfg_path == Path.join(dir, "Bank.cfg")
  end

  test "fair_actions extracts the name inside WF_/SF_(...), across subscript forms", %{
    tmp_dir: dir
  } do
    write(dir, [
      {"X.tla",
       ~S"""
       ---- MODULE X ----
       VARIABLE status
       Spec == Init /\ [][Next]_status /\ WF_status(Reap)
               /\ SF_<<x, y>>(Kill)
               /\ \A u \in U : WF_vars(Pay(u))
       ====
       """}
    ])

    spec = Spec.from_path(Path.join(dir, "X.tla"))
    assert {:ok, MapSet.new(["Reap", "Kill", "Pay"])} == Spec.fair_actions(spec)
  end

  test "fair_actions strips \\* line comments and (* *) block comments first", %{tmp_dir: dir} do
    write(dir, [
      {"X.tla",
       ~S"""
       ---- MODULE X ----
       \* WF_vars(FromLineComment) should not count
       (* WF_vars(FromBlockComment)
          spans multiple lines *)
       Spec == WF_vars(Real)
       ====
       """}
    ])

    spec = Spec.from_path(Path.join(dir, "X.tla"))
    assert {:ok, MapSet.new(["Real"])} == Spec.fair_actions(spec)
  end

  test "fair_actions treats (* (* *) *) block comments as nested, not as ending at the first *)",
       %{tmp_dir: dir} do
    write(dir, [
      {"X.tla",
       ~S"""
       ---- MODULE X ----
       (* outer (* inner *) WF_vars(ShouldNotBeFound) still a comment *)
       Spec == WF_vars(Real)
       ====
       """}
    ])

    spec = Spec.from_path(Path.join(dir, "X.tla"))
    assert {:ok, MapSet.new(["Real"])} == Spec.fair_actions(spec)
  end

  test "fair_actions returns names even when they are not actual graph actions (e.g. Next)", %{
    tmp_dir: dir
  } do
    write(dir, [
      {"X.tla",
       ~S"""
       Spec == Init /\ [][Next]_vars /\ WF_vars(Next)
       """}
    ])

    spec = Spec.from_path(Path.join(dir, "X.tla"))
    assert {:ok, MapSet.new(["Next"])} == Spec.fair_actions(spec)
  end

  test "an unclosed (* inside a \\* line comment doesn't blank the rest of the file", %{
    tmp_dir: dir
  } do
    write(dir, [
      {"X.tla",
       ~S"""
       ---- MODULE X ----
       VARIABLE x
       \* old syntax (* was used
       Tick == /\ x' = x + 1
       Spec == WF_x(Tick)
       ====
       """}
    ])

    spec = Spec.from_path(Path.join(dir, "X.tla"))
    assert {:ok, MapSet.new(["Tick"])} == Spec.fair_actions(spec)
  end

  test "a \\* inside a string literal is not treated as a comment" do
    text = ~S{Foo == "price \* not a comment" /\ Bar(x)}
    assert Spec.strip_comments(text) == text
  end

  test "content hash changes with the spec, its cfg, or a sibling module", %{tmp_dir: dir} do
    write(dir, [{"A.tla", "a"}, {"A.cfg", "c"}, {"Helper.tla", "h"}])
    {:ok, spec} = Spec.fetch("A", dir)
    {:ok, h1} = Spec.content_hash(spec)
    assert h1 == elem(Spec.content_hash(spec), 1)

    for {file, body} <- [{"A.cfg", "c2"}, {"Helper.tla", "h2"}, {"A.tla", "a2"}] do
      before = elem(Spec.content_hash(spec), 1)
      File.write!(Path.join(dir, file), body)
      refute elem(Spec.content_hash(spec), 1) == before
    end
  end

  test "content_hash and fair_actions report a missing spec file as an actionable error", %{
    tmp_dir: dir
  } do
    write(dir, [{"A.tla", "a"}, {"A.cfg", "c"}])
    {:ok, spec} = Spec.fetch("A", dir)
    File.rm!(Path.join(dir, "A.cfg"))

    assert {:error, %Outlaw.Error{kind: :unknown_spec, message: msg}} = Spec.content_hash(spec)
    assert msg =~ "A.cfg"
    assert msg =~ "spec:"

    spec = Spec.from_path(Path.join(dir, "Missing.tla"))

    assert {:error, %Outlaw.Error{kind: :unknown_spec, message: msg}} = Spec.fair_actions(spec)
    assert msg =~ "Missing.tla"
  end
end
