defmodule Notary.ToolsTest do
  use ExUnit.Case, async: false

  alias Notary.Tools

  @moduletag :tmp_dir

  setup do
    on_exit(fn ->
      Application.delete_env(:notary, :tla2tools_path)
      Application.delete_env(:notary, :java)
    end)
  end

  test "parses java version banners" do
    assert Tools.java_major_version(~s(openjdk version "21.0.12.1" 2026-08-18)) == 21
    assert Tools.java_major_version(~s(java version "1.8.0_382")) == 8
    assert Tools.java_major_version(~s(openjdk version "11.0.2" 2019-01-15)) == 11
    assert Tools.java_major_version("garbage") == nil
  end

  test "missing java is an actionable error" do
    Application.put_env(:notary, :java, "definitely-not-java-xyz")
    assert {:error, %Notary.Error{kind: :java_not_found, message: msg}} = Tools.find_java()
    assert msg =~ "nix"
  end

  test "missing jar points at mix notary.install", %{tmp_dir: dir} do
    Application.put_env(:notary, :tla2tools_path, Path.join(dir, "missing.jar"))
    assert {:error, %Notary.Error{kind: :jar_not_found, message: msg}} = Tools.find_jar()
    assert msg =~ "mix notary.install"
  end

  test "install is a no-op when the jar already matches the checksum", %{tmp_dir: dir} do
    jar = Path.join(dir, "tla2tools.jar")
    File.write!(jar, "pretend jar")
    Application.put_env(:notary, :tla2tools_path, jar)
    sha = Tools.sha256_file(jar)
    assert Tools.install(sha256: sha, url: "https://invalid.example/never-fetched") == {:ok, jar}
  end

  @tag :network
  test "downloads and verifies the pinned jar", %{tmp_dir: dir} do
    Application.put_env(:notary, :tla2tools_path, Path.join(dir, "tla2tools.jar"))
    assert {:ok, path} = Tools.install()
    assert Tools.sha256_file(path) == Notary.Config.jar_sha256()
  end

  @tag :network
  test "a checksum mismatch is rejected and nothing is written", %{tmp_dir: dir} do
    jar = Path.join(dir, "tla2tools.jar")
    Application.put_env(:notary, :tla2tools_path, jar)

    assert {:error, %Notary.Error{kind: :checksum_mismatch}} =
             Tools.install(sha256: String.duplicate("0", 64))

    refute File.exists?(jar)
  end
end
