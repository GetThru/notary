defmodule Outlaw.CLI do
  @moduledoc false
  # Shared plumbing for the mix tasks.

  alias Outlaw.{Config, Report, Spec}

  @switches [
    json: :boolean,
    seed: :integer,
    max_runs: :integer,
    max_steps: :integer,
    force: :boolean
  ]

  def parse!(args, extra \\ []) do
    {opts, names, invalid} = OptionParser.parse(args, strict: @switches ++ extra)

    if invalid != [],
      do: Mix.raise("Unknown or invalid options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")

    {opts, names}
  end

  def specs!(names) do
    dir = Config.specs_dir()

    case Spec.select(names, dir) do
      {:ok, []} ->
        Mix.raise(
          "No specs found in #{Path.relative_to_cwd(dir)}. Create one with `mix outlaw.new Name`."
        )

      {:ok, specs} ->
        specs

      {:error, error} ->
        Mix.raise(error.message)
    end
  end

  def ensure_test_env!(task) do
    if Mix.env() != :test do
      Mix.raise("""
      mix #{task} must run in the test environment (mapping modules live under test/outlaw/). Add to mix.exs:

          def cli, do: [preferred_envs: ["outlaw.test": :test, "outlaw.verify": :test]]

      or run: MIX_ENV=test mix #{task}
      """)
    end
  end

  def load_mappings! do
    Mix.Task.run("compile")
    Mix.Task.run("app.start")
    helper = "test/outlaw/outlaw_helper.exs"
    if File.exists?(helper), do: Code.require_file(helper)
    Outlaw.Conformance.discover_mappings(Mix.Project.config()[:app])
  end

  def conformance_opts(opts), do: Keyword.take(opts, [:seed, :max_runs, :max_steps, :force])

  def finish(report, opts) do
    if opts[:json] do
      json = JSON.encode!(Report.to_json(report))
      path = Path.join(Config.work_dir(), "report.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, json)
      IO.puts(json)
    else
      IO.puts(Report.format(report))
    end

    if report.status != :pass, do: exit({:shutdown, 1})
    :ok
  end
end
