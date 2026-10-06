defmodule Mix.Tasks.Notary.Test do
  @shortdoc "Runs conformance tests of the implementation against the specs"
  @moduledoc """
  Builds (or loads the cached) state graph for each spec and drives the
  implementation through generated action sequences via its mapping module.

      mix notary.test [Name ...] [--json] [--seed N] [--max-runs N] [--max-steps N] [--force]

  Runs in the test environment. Requires `test/notary/notary_helper.exs` if your
  app needs setup (e.g. Ecto sandbox mode) before conformance runs.
  """
  use Mix.Task

  alias Notary.{CLI, Verify}

  @impl true
  def run(args) do
    CLI.ensure_test_env!("notary.test")
    {opts, names} = CLI.parse!(args)
    mappings = CLI.load_mappings!()

    results =
      Enum.map(CLI.specs!(names), &Verify.test_spec(&1, mappings, CLI.conformance_opts(opts)))

    CLI.finish(Verify.report(nil, results), opts)
  end
end
