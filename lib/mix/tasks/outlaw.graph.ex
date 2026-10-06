defmodule Mix.Tasks.Outlaw.Graph do
  @shortdoc "Renders a spec's state graph as an interactive HTML page or Mermaid"
  @moduledoc """
      mix outlaw.graph Name [--format html|mermaid] [--trace failure|counterexample] [--open]

    * no `--trace`: the full reachable state graph
    * `--trace failure`: the last conformance failure recorded by `mix outlaw.test`
    * `--trace counterexample`: TLC's counterexample for a failing spec

  HTML is written to `_build/outlaw/`; Mermaid is printed to stdout.
  """
  use Mix.Task

  alias Outlaw.{CLI, TLC, Viewer}
  alias Outlaw.Viewer.Mermaid

  @usage "Usage: mix outlaw.graph Name [--format html|mermaid] [--trace failure|counterexample] [--open]"

  @impl true
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args, strict: [format: :string, trace: :string, open: :boolean])

    if invalid != [], do: Mix.raise(@usage)

    name =
      case argv do
        [name] -> name
        _ -> Mix.raise(@usage)
      end

    [spec] = CLI.specs!([name])
    {basename, model} = model!(spec, opts[:trace])

    case Keyword.get(opts, :format, "html") do
      "html" ->
        path = Viewer.write(basename, model)
        Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
        if opts[:open], do: open(path)

      "mermaid" ->
        if opts[:open], do: Mix.raise("--open is only supported with --format html")
        IO.write(Mermaid.render(model))

      other ->
        Mix.raise("Unknown --format #{other}. #{@usage}")
    end
  end

  defp model!(spec, nil) do
    case TLC.graph(spec) do
      {:ok, graph, _} ->
        {spec.name, Viewer.from_graph(graph, title: "#{spec.name} state graph")}

      {:violation, _} ->
        Mix.raise(
          "#{spec.name} fails model checking, so there is no complete graph. Use --trace counterexample."
        )

      {:error, error} ->
        Mix.raise(error.message)
    end
  end

  defp model!(spec, "failure") do
    with {:ok, failure} <- Viewer.read_failure(spec.name),
         {:ok, graph, _} <- TLC.graph(spec) do
      {spec.name <> "-failure", Viewer.failure_model(spec.name, graph, failure)}
    else
      :error ->
        Mix.raise(
          "No recorded conformance failure for #{spec.name}. Run `mix outlaw.test #{spec.name}` first."
        )

      {:violation, _} ->
        Mix.raise("#{spec.name} fails model checking. Use --trace counterexample.")

      {:error, error} ->
        Mix.raise(error.message)
    end
  end

  defp model!(spec, "counterexample") do
    case TLC.check(spec) do
      {:violation, v} ->
        {spec.name <> "-counterexample", Viewer.from_trace("#{spec.name}: counterexample", v)}

      {:ok, _} ->
        Mix.raise("#{spec.name} passes model checking; there is no counterexample.")

      {:error, error} ->
        Mix.raise(error.message)
    end
  end

  defp model!(_spec, other), do: Mix.raise("Unknown --trace #{other}. #{@usage}")

  defp open(path) do
    command =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:win32, _} -> "explorer"
        _ -> "xdg-open"
      end

    case System.cmd(command, [path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, status} ->
        Mix.raise(
          "Could not open #{path}: #{command} exited #{status}#{hint(output)}." <>
            " Open it manually."
        )
    end
  rescue
    e in ErlangError ->
      command =
        case :os.type() do
          {:unix, :darwin} -> "open"
          {:win32, _} -> "explorer"
          _ -> "xdg-open"
        end

      Mix.raise(
        "Could not open #{path}: #{command} not found (#{Exception.message(e)})." <>
          " Open the file manually."
      )
  end

  defp hint(output) do
    case String.trim(output || "") do
      "" -> ""
      trimmed -> ": #{trimmed}"
    end
  end
end
