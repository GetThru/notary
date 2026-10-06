defmodule Notary.Config do
  @moduledoc """
  Notary configuration (`config :notary, ...`) with defaults, plus the pinned
  TLA+ tools metadata.
  """

  @defaults [
    specs_dir: "specs",
    work_dir: nil,
    tla2tools_path: nil,
    java: "java",
    endpoint: nil,
    tlc_workers: "auto",
    tlc_timeout: 300_000,
    max_states: 100_000,
    max_runs: 100,
    max_steps: 50,
    action_timeout: 5_000,
    settle_timeout: 1_000
  ]

  @tla_version "1.7.4"

  @spec get(atom()) :: term()
  def get(key) when is_atom(key) do
    Application.get_env(:notary, key, Keyword.fetch!(@defaults, key))
  end

  @doc "Directory for Notary's generated files (`_build/notary` by default)."
  @spec work_dir() :: String.t()
  def work_dir do
    case get(:work_dir) do
      nil -> default_work_dir()
      dir -> Path.expand(dir)
    end
  end

  @doc """
  Path to the pinned TLA+ tools jar. Defaults to `tla2tools.jar` inside the
  *default* work dir (`_build/notary`), not the possibly-overridden `work_dir/0` —
  overriding `config :notary, work_dir:` only relocates generated artifacts (cache,
  reports, HTML), not the installed jar. Override the jar location independently
  with `config :notary, tla2tools_path:`, or with the `NOTARY_TLA2TOOLS`
  environment variable (which the Notary nix flake's shells set to a jar in the
  nix store). Config wins over the environment variable.
  """
  @spec jar_path() :: String.t()
  def jar_path do
    get(:tla2tools_path) || env_jar_path() || Path.join(default_work_dir(), "tla2tools.jar")
  end

  defp env_jar_path do
    case System.get_env("NOTARY_TLA2TOOLS") do
      nil -> nil
      "" -> nil
      path -> path
    end
  end

  defp default_work_dir, do: Path.expand("../notary", Mix.Project.build_path())

  @spec specs_dir() :: String.t()
  def specs_dir, do: Path.expand(get(:specs_dir))

  @spec tla_version() :: String.t()
  def tla_version, do: @tla_version

  @spec jar_url() :: String.t()
  def jar_url,
    do: "https://github.com/tlaplus/tlaplus/releases/download/v#{@tla_version}/tla2tools.jar"

  @spec jar_sha256() :: String.t()
  def jar_sha256, do: "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
end
