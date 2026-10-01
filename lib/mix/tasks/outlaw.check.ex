defmodule Mix.Tasks.Outlaw.Check do
  @shortdoc "Model-checks TLA+ specs with TLC"
  @moduledoc """
  Runs TLC on every spec in the specs directory (or only the named ones).

      mix outlaw.check [Name ...] [--json]

  Exits with status 1 if any spec has a violation or error.
  """
  use Mix.Task

  alias Outlaw.{CLI, Verify}

  @impl true
  def run(args) do
    {opts, names} = CLI.parse!(args)
    results = Enum.map(CLI.specs!(names), &Verify.check_spec/1)
    CLI.finish(Verify.report(nil, results), opts)
  end
end
