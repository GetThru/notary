defmodule Outlaw.Viewer do
  @moduledoc """
  Builds viewer models from state graphs, TLC counterexamples and conformance
  failures, and renders them as a self-contained interactive HTML page.
  """

  alias Outlaw.{Config, StateGraph, Value}
  alias Outlaw.Conformance.Failure

  @type model :: %{
          title: String.t(),
          note: String.t() | nil,
          nodes: [%{id: String.t(), vars: %{String.t() => String.t()}, initial: boolean()}],
          edges: [%{source: String.t(), target: String.t(), action: String.t()}],
          highlight: [String.t()]
        }

  @spec from_graph(StateGraph.t(), keyword()) :: model()
  def from_graph(%StateGraph{} = graph, opts \\ []) do
    initial = MapSet.new(graph.initial)

    %{
      title: Keyword.get(opts, :title, "State graph"),
      note: Keyword.get(opts, :note),
      nodes:
        for(
          {id, vars} <- Enum.sort(graph.states),
          do: %{id: id, vars: render_vars(vars), initial: MapSet.member?(initial, id)}
        ),
      edges:
        for(
          {from, action, to} <- StateGraph.edges(graph),
          do: %{source: from, target: to, action: action}
        ),
      highlight: Keyword.get(opts, :highlight, [])
    }
  end

  @spec from_trace(String.t(), map()) :: model()
  def from_trace(title, %{trace: trace} = violation) do
    states = Enum.filter(trace, &Map.has_key?(&1, :state))

    nodes =
      Enum.map(
        states,
        &%{id: "t#{&1.index}", vars: render_vars(&1.state), initial: &1.index == 1}
      )

    forward =
      states
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        %{source: "t#{a.index}", target: "t#{b.index}", action: b.action || "?"}
      end)

    last = states |> List.last() |> then(&"t#{&1.index}")

    extra =
      Enum.flat_map(trace, fn
        %{back_to: n} -> [%{source: last, target: "t#{n}", action: "(loop)"}]
        %{stuttering: true} -> [%{source: last, target: last, action: "(stutter)"}]
        _ -> []
      end)

    %{
      title: title,
      note: violation.message,
      nodes: nodes,
      edges: forward ++ extra,
      highlight: Enum.map(nodes, & &1.id)
    }
  end

  @spec failure_model(String.t(), StateGraph.t(), Failure.t()) :: model()
  def failure_model(spec_name, graph, %Failure{} = failure) do
    highlight = failure.steps |> Enum.flat_map(& &1.candidates) |> Enum.uniq()
    last = List.last(failure.steps)

    note =
      "#{failure.kind} at step #{last && last.index}: implementation state " <>
        "#{last && Outlaw.Report.format_state(last.projection)}. Highlighted: spec states the run passed through."

    from_graph(graph,
      title: "#{spec_name}: conformance failure (#{failure.kind})",
      note: note,
      highlight: highlight
    )
  end

  @spec html(model()) :: String.t()
  def html(model) do
    data = model |> JSON.encode!() |> String.replace("</", "<\\/")

    EEx.eval_file(asset("viewer.html.eex"),
      assigns: [
        title: escape_html(model.title),
        data: data,
        cytoscape: inline_js(asset("cytoscape.min.js")),
        app: inline_js(asset("viewer.js"))
      ]
    )
  end

  @spec write(String.t(), model()) :: String.t()
  def write(basename, model) do
    path = Path.join(Config.work_dir(), basename <> ".html")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, html(model))
    path
  end

  @spec write_failure(String.t(), StateGraph.t(), Failure.t()) :: String.t()
  def write_failure(spec_name, graph, %Failure{} = failure) do
    File.mkdir_p!(Config.work_dir())
    File.write!(failure_term_path(spec_name), :erlang.term_to_binary(failure))
    write(spec_name <> "-failure", failure_model(spec_name, graph, failure))
  end

  @spec read_failure(String.t()) :: {:ok, Failure.t()} | :error
  def read_failure(spec_name) do
    case File.read(failure_term_path(spec_name)) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      {:error, _} -> :error
    end
  end

  defp failure_term_path(spec_name),
    do: Path.join(Config.work_dir(), spec_name <> "-failure.term")

  defp render_vars(vars), do: Map.new(vars, fn {k, v} -> {k, Value.to_tla(v)} end)

  defp asset(name), do: Path.join([:code.priv_dir(:outlaw), "viewer", name])

  defp inline_js(path), do: path |> File.read!() |> String.replace("</script", "<\\/script")

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
