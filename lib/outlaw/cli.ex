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

  @doc """
  Encodes `map` as JSON, writes it to `<work_dir>/report.json`, and prints it
  as the last line of stdout. Shared by every mix task's `--json` output so
  the report file is always kept in sync with stdout.
  """
  def emit_json(map) do
    json = JSON.encode!(map)
    path = Path.join(Config.work_dir(), "report.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json)
    IO.puts(json)
  end

  def finish(report, opts) do
    if opts[:json] do
      emit_json(Report.to_json(report))
    else
      IO.puts(Report.format(report, colors: colors?(opts[:json])))
    end

    if report.status != :pass, do: exit({:shutdown, 1})
    :ok
  end

  # Colors only when stdout is a real terminal: ANSI itself enabled, and
  # stdout a TTY (not piped/redirected) -- design spec §9.1. `--json` is
  # checked here too (belt and braces; `finish/2` already skips this branch
  # entirely when it's set).
  #
  # `:io.columns/1` wants Erlang's `:standard_io` -- Elixir's `:stdio` is not
  # a device `:io.columns/1` recognizes, so passing it always answers
  # `{:error, :enotsup}`, even on a real pty, which silently disabled colors
  # everywhere.
  defp colors?(json?), do: colors?(IO.ANSI.enabled?(), :io.columns(:standard_io), json?)

  @doc false
  @spec colors?(boolean(), {:ok, pos_integer()} | {:error, term()}, boolean() | nil) :: boolean()
  def colors?(ansi_enabled?, columns_result, json?) do
    not json? and ansi_enabled? and match?({:ok, _}, columns_result)
  end
end
