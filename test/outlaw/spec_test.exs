defmodule Outlaw.SpecTest do
  use ExUnit.Case, async: true

  alias Outlaw.Spec

  @moduletag :tmp_dir

  defp write(dir, files), do: Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)

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

  test "content hash changes with the spec, its cfg, or a sibling module", %{tmp_dir: dir} do
    write(dir, [{"A.tla", "a"}, {"A.cfg", "c"}, {"Helper.tla", "h"}])
    {:ok, spec} = Spec.fetch("A", dir)
    h1 = Spec.content_hash(spec)
    assert h1 == Spec.content_hash(spec)

    for {file, body} <- [{"A.cfg", "c2"}, {"Helper.tla", "h2"}, {"A.tla", "a2"}] do
      before = Spec.content_hash(spec)
      File.write!(Path.join(dir, file), body)
      refute Spec.content_hash(spec) == before
    end
  end
end
