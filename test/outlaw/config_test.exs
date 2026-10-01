defmodule Outlaw.ConfigTest do
  use ExUnit.Case, async: false

  alias Outlaw.Config

  setup do
    on_exit(fn ->
      for key <- [:max_states, :work_dir, :tla2tools_path],
          do: Application.delete_env(:outlaw, key)
    end)
  end

  test "returns defaults" do
    assert Config.get(:max_states) == 100_000
    assert Config.get(:tlc_workers) == "auto"
    assert Config.get(:java) == "java"
  end

  test "application env overrides defaults" do
    Application.put_env(:outlaw, :max_states, 10)
    assert Config.get(:max_states) == 10
  end

  test "unknown keys raise" do
    assert_raise KeyError, fn -> Config.get(:nope) end
  end

  test "work_dir defaults to _build/outlaw and jar lives inside it" do
    assert Config.work_dir() |> Path.split() |> Enum.take(-2) == ["_build", "outlaw"]
    assert Config.jar_path() == Path.join(Config.work_dir(), "tla2tools.jar")
  end

  test "work_dir and jar path can be overridden" do
    Application.put_env(:outlaw, :work_dir, "/tmp/outlaw-x")
    Application.put_env(:outlaw, :tla2tools_path, "/opt/tla2tools.jar")
    assert Config.work_dir() == "/tmp/outlaw-x"
    assert Config.jar_path() == "/opt/tla2tools.jar"
  end

  test "pinned tools metadata" do
    assert Config.tla_version() == "1.7.4"
    assert Config.jar_url() =~ "v1.7.4/tla2tools.jar"
    assert byte_size(Config.jar_sha256()) == 64
  end
end
