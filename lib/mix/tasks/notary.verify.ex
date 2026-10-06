defmodule Mix.Tasks.Notary.Verify do
  @shortdoc "Lock check, model check and conformance test for all specs"
  @moduledoc """
  The one command for humans, LLM agents and CI:

      mix notary.verify [--json] [--seed N] [--max-runs N] [--max-steps N] [--force]

  1. Fails if spec files changed since the last `mix notary.lock`.
  2. Model-checks every spec with TLC.
  3. Runs conformance tests through each spec's mapping module.

  With `--json`, the last line of stdout is the JSON report (also written to
  `<work_dir>/report.json`, default `_build/notary/report.json`).
  """
  use Mix.Task

  alias Notary.{CLI, Config, Verify}

  @impl true
  def run(args) do
    CLI.ensure_test_env!("notary.verify")
    {opts, names} = CLI.parse!(args)
    mappings = CLI.load_mappings!()
    lock = Verify.lock_stage(Config.specs_dir())

    results =
      Enum.map(CLI.specs!(names), &Verify.test_spec(&1, mappings, CLI.conformance_opts(opts)))

    CLI.finish(Verify.report(lock, results), opts)
  end
end
