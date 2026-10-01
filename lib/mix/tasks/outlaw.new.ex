defmodule Mix.Tasks.Outlaw.New do
  @shortdoc "Scaffolds a new TLA+ spec (and its mapping module)"
  @moduledoc """
      mix outlaw.new Name [--no-mapping]

  Creates `specs/Name.tla`, `specs/Name.cfg`, `specs/AGENTS.md` (once), and
  unless `--no-mapping`, `test/outlaw/name_spec.ex` plus a conformance test.
  Never overwrites existing files.
  """
  use Mix.Task

  alias Outlaw.{Config, Scaffold}

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [no_mapping: :boolean])
    if invalid != [], do: Mix.raise("Unknown option. Usage: mix outlaw.new Name [--no-mapping]")

    name =
      case argv do
        [name] -> name
        _ -> Mix.raise("Usage: mix outlaw.new Name [--no-mapping]")
      end

    unless Regex.match?(~r/^[A-Z][A-Za-z0-9]*$/, name),
      do:
        Mix.raise(
          "Spec name must be CamelCase, like Bank or CheckoutFlow (got #{inspect(name)})."
        )

    mapping? = not Keyword.get(opts, :no_mapping, false)
    app_module = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()

    files =
      Scaffold.files(name,
        specs_dir: Path.relative_to_cwd(Config.specs_dir()),
        app_module: app_module,
        mapping: mapping?
      )

    case Scaffold.write(files) do
      {:ok, written} ->
        Enum.each(written, &Mix.shell().info("* creating #{&1}"))
        Mix.shell().info(Scaffold.next_steps(name, mapping?))

      {:error, conflicts} ->
        Mix.raise(
          "Refusing to overwrite existing files:\n" <> Enum.map_join(conflicts, "\n", &"  #{&1}")
        )
    end
  end
end
