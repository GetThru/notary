defmodule Notary.CacheTest do
  use ExUnit.Case, async: false

  alias Notary.{Cache, Spec}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:notary, :work_dir, Path.join(dir, "work"))
    on_exit(fn -> Application.delete_env(:notary, :work_dir) end)
    File.write!(Path.join(dir, "A.tla"), "a")
    File.write!(Path.join(dir, "A.cfg"), "c")
    {:ok, spec} = Spec.fetch("A", dir)
    %{spec: spec, dir: dir}
  end

  test "miss, put, hit", %{spec: spec} do
    {:ok, key} = Cache.key(spec)
    assert key =~ ~r/^A-[0-9a-f]{16}$/
    assert Cache.get(key) == :miss
    assert Cache.put(key, %{graph: %{vars: %{}}, stats: %{distinct_states: 1}}) == :ok

    assert Cache.get(key) ==
             {:ok, %{graph: %{vars: %{}}, stats: %{distinct_states: 1}}}
  end

  test "an entry without the graph shape is a miss (older-format drift)", %{spec: spec} do
    {:ok, key} = Cache.key(spec)
    File.mkdir_p!(Path.dirname(Cache.path(key)))
    File.write!(Cache.path(key), :erlang.term_to_binary(%{graph: :old_shape, stats: %{}}))
    assert Cache.get(key) == :miss
  end

  test "key changes when the spec changes and old entries are removed", %{spec: spec, dir: dir} do
    {:ok, old} = Cache.key(spec)
    entry = %{graph: %{vars: %{}}, stats: %{}}
    Cache.put(old, entry)
    File.write!(Path.join(dir, "A.tla"), "a changed")
    {:ok, new} = Cache.key(spec)
    refute new == old
    Cache.put(new, entry)
    assert Cache.get(old) == :miss
    assert Cache.get(new) == {:ok, entry}
  end

  test "corrupt entries are a miss", %{spec: spec} do
    {:ok, key} = Cache.key(spec)
    File.mkdir_p!(Path.dirname(Cache.path(key)))
    File.write!(Cache.path(key), "not a term")
    assert Cache.get(key) == :miss
  end

  test "specs with hyphens in name don't collide on cleanup", %{tmp_dir: _dir} do
    # Put entries for "My" and "My-Spec" specs with same first hash digits
    my_key = "My-0123456789abcdef"
    my_spec_key = "My-Spec-0123456789abcdef"
    entry = %{graph: %{vars: %{}}, stats: %{}}

    Cache.put(my_key, entry)
    Cache.put(my_spec_key, entry)

    # Verify both are cached
    assert Cache.get(my_key) == {:ok, entry}
    assert Cache.get(my_spec_key) == {:ok, entry}

    # Put a new version of "My-Spec" with different hash
    new_my_spec_key = "My-Spec-fedcba9876543210"
    Cache.put(new_my_spec_key, entry)

    # Old "My-Spec" entry should be deleted, "My" entry should remain
    assert Cache.get(my_key) == {:ok, entry}
    assert Cache.get(my_spec_key) == :miss
    assert Cache.get(new_my_spec_key) == {:ok, entry}
  end
end
