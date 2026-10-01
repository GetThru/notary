defmodule Outlaw.CacheTest do
  use ExUnit.Case, async: false

  alias Outlaw.{Cache, Spec}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:outlaw, :work_dir, Path.join(dir, "work"))
    on_exit(fn -> Application.delete_env(:outlaw, :work_dir) end)
    File.write!(Path.join(dir, "A.tla"), "a")
    File.write!(Path.join(dir, "A.cfg"), "c")
    {:ok, spec} = Spec.fetch("A", dir)
    %{spec: spec, dir: dir}
  end

  test "miss, put, hit", %{spec: spec} do
    key = Cache.key(spec)
    assert key =~ ~r/^A-[0-9a-f]{16}$/
    assert Cache.get(key) == :miss
    assert Cache.put(key, %{graph: :g}) == :ok
    assert Cache.get(key) == {:ok, %{graph: :g}}
  end

  test "key changes when the spec changes and old entries are removed", %{spec: spec, dir: dir} do
    old = Cache.key(spec)
    Cache.put(old, :old)
    File.write!(Path.join(dir, "A.tla"), "a changed")
    new = Cache.key(spec)
    refute new == old
    Cache.put(new, :new)
    assert Cache.get(old) == :miss
    assert Cache.get(new) == {:ok, :new}
  end

  test "corrupt entries are a miss", %{spec: spec} do
    key = Cache.key(spec)
    File.mkdir_p!(Path.dirname(Cache.path(key)))
    File.write!(Cache.path(key), "not a term")
    assert Cache.get(key) == :miss
  end
end
