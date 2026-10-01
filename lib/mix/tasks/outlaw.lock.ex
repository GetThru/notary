defmodule Mix.Tasks.Outlaw.Lock do
  @shortdoc "Records the current spec files as reviewed (human step)"
  @moduledoc """
  Writes `specs/.outlaw.lock` with hashes of every `.tla`/`.cfg` in the specs
  directory. Run this yourself after intentionally changing a spec; LLM agents
  must never run it.

      mix outlaw.lock [--json]
  """
  use Mix.Task

  alias Outlaw.{CLI, Config, Lock}

  @impl true
  def run(args) do
    {opts, _} = CLI.parse!(args)
    dir = Config.specs_dir()
    {:ok, files} = Lock.write(dir)

    if opts[:json] do
      CLI.emit_json(%{"status" => "pass", "locked" => files})
    else
      Mix.shell().info(
        "Locked #{length(files)} spec files in #{Path.relative_to_cwd(Lock.path(dir))}:\n" <>
          Enum.map_join(files, "\n", &"  #{&1}")
      )
    end
  end
end
