defmodule Mix.Tasks.Notary.Install do
  @shortdoc "Downloads the pinned TLA+ tools and checks Java"
  @moduledoc """
      mix notary.install [--force]

  Downloads tla2tools.jar (pinned version, checksum-verified) into
  `_build/notary/` and checks that Java >= 11 is available.
  """
  use Mix.Task

  alias Notary.{Config, Tools}

  @impl true
  def run(args) do
    {opts, extra_args, invalid} = OptionParser.parse(args, strict: [force: :boolean])

    if invalid != [] or extra_args != [] do
      Mix.raise("Usage: mix notary.install [--force]")
    end

    case Tools.install(force: Keyword.get(opts, :force, false)) do
      {:ok, path} ->
        Mix.shell().info(
          "tla2tools.jar v#{Config.tla_version()} ready at #{Path.relative_to_cwd(path)}"
        )

      {:error, error} ->
        Mix.raise(error.message)
    end

    case Tools.find_java() do
      {:ok, java} ->
        Mix.shell().info("Java OK: #{java}")

      {:error, error} ->
        Mix.shell().error(error.message)
        exit({:shutdown, 1})
    end
  end
end
