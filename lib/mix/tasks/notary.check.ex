defmodule Mix.Tasks.Notary.Check do
  @shortdoc "Model-checks TLA+ specs with TLC"
  @moduledoc """
  Runs TLC on every spec in the specs directory (or only the named ones).

      mix notary.check [Name ...] [--json]

  Exits with status 1 if any spec has a violation or error.
  """
  use Mix.Task

  alias Notary.{CLI, Verify}

  @impl true
  def run(args) do
    # No --seed/--max-runs/--max-steps/--force: those drive conformance, not
    # TLC (`mix notary.check` model-checks the spec alone), so accepting them
    # silently would pretend they did something.
    {opts, names} = CLI.parse!(args, only: [:json])
    Mix.Tasks.Notary.Compile.sync_and_report()
    results = Enum.map(CLI.specs!(names), &Verify.check_spec/1)
    CLI.finish(Verify.report(nil, results), opts)
  end
end
