defmodule Outlaw.LockTest do
  use ExUnit.Case, async: true

  alias Outlaw.Lock

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Bank.tla"), "spec")
    File.write!(Path.join(dir, "Bank.cfg"), "cfg")
    :ok
  end

  test "a directory with no lock file reports every spec file as unlocked", %{tmp_dir: dir} do
    assert Lock.changes(dir) == [{:unlocked, "Bank.cfg"}, {:unlocked, "Bank.tla"}]
    assert {:error, %Outlaw.Error{kind: :spec_lock_mismatch} = e} = Lock.check(dir)
    assert e.message =~ "mix outlaw.lock"
    assert e.message =~ "do not edit specs"
  end

  test "write then check passes, and the file is stable sorted JSON", %{tmp_dir: dir} do
    assert {:ok, ["Bank.cfg", "Bank.tla"]} = Lock.write(dir)
    assert Lock.check(dir) == :ok
    body = File.read!(Lock.path(dir))
    assert %{"version" => 1, "files" => %{"Bank.tla" => _, "Bank.cfg" => _}} = JSON.decode!(body)
    {:ok, _} = Lock.write(dir)
    assert File.read!(Lock.path(dir)) == body
  end

  test "detects changed, unlocked and removed files", %{tmp_dir: dir} do
    {:ok, _} = Lock.write(dir)
    File.write!(Path.join(dir, "Bank.tla"), "edited by someone")
    File.write!(Path.join(dir, "New.tla"), "new")
    File.rm!(Path.join(dir, "Bank.cfg"))

    assert Lock.changes(dir) == [
             {:changed, "Bank.tla"},
             {:removed, "Bank.cfg"},
             {:unlocked, "New.tla"}
           ]

    assert {:error, %Outlaw.Error{details: %{changes: [_, _, _]}}} = Lock.check(dir)
  end

  test "corrupt lock file (invalid JSON) returns spec_lock_corrupt error from check/1", %{
    tmp_dir: dir
  } do
    File.write!(Lock.path(dir), "{not valid json")
    assert {:error, %Outlaw.Error{kind: :spec_lock_corrupt} = e} = Lock.check(dir)
    assert e.message =~ Lock.path(dir)
    assert e.message =~ "do not edit or regenerate the lock"
  end

  test "lock file without files key returns spec_lock_corrupt error from check/1", %{tmp_dir: dir} do
    File.write!(Lock.path(dir), ~s({"version": 1}))
    assert {:error, %Outlaw.Error{kind: :spec_lock_corrupt} = e} = Lock.check(dir)
    assert e.message =~ Lock.path(dir)
    assert e.message =~ "do not edit or regenerate the lock"
  end

  test "changes/1 raises Outlaw.Error when lock is corrupt", %{tmp_dir: dir} do
    File.write!(Lock.path(dir), "{not valid json")
    assert_raise Outlaw.Error, fn -> Lock.changes(dir) end
  end
end
