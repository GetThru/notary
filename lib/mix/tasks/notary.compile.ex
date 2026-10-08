defmodule Mix.Tasks.Notary.Compile do
  @shortdoc "Generates specs/*.tla + *.cfg from Notary.DSL spec modules"
  @moduledoc """
  Writes the TLA+ files for every `use Notary.DSL` spec module:

      mix notary.compile

  Generated files live in the specs directory and carry a GENERATED marker.
  A DSL module whose generated name collides with a hand-written spec file
  fails the run rather than overwriting. Files whose content is already
  current are left alone (stable mtimes for watchers).

  This runs automatically before `mix notary.check`, `mix notary.test`,
  `mix notary.verify`, and `mix notary.lock`, so calling it yourself is only
  needed to inspect what the DSL emits.
  """
  use Mix.Task

  alias Notary.DSL.Compile
  alias Notary.CLI

  @impl true
  def run(args) do
    {opts, names} = CLI.parse!(args, only: [:json])

    unless names == [] do
      Mix.raise("mix notary.compile takes no spec names (it syncs every DSL module).")
    end

    sync_and_report(opts)
  end

  @doc false
  @spec sync_and_report(keyword()) :: :ok | no_return()
  def sync_and_report(opts \\ []) do
    case Compile.sync(opts) do
      {:ok, written, _unchanged} ->
        written = Enum.sort(written)

        if written != [] do
          Mix.shell().info(
            (opts[:json] == nil &&
               Enum.map_join(written, "\n", &"* writing #{Path.relative_to_cwd(&1)}")) ||
              ""
          )
        end

        :ok

      {:error, error} ->
        Mix.raise(error.message)
    end
  end
end
