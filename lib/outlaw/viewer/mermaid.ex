defmodule Outlaw.Viewer.Mermaid do
  @moduledoc """
  Renders a viewer model as a Mermaid `stateDiagram-v2`, which displays inline in
  GitHub and markdown and is easy for LLMs to read. Above #{50} states, only the
  highlighted path (or a breadth-first prefix from the initial states) is shown.
  """

  @max 50

  @spec render(Outlaw.Viewer.model()) :: String.t()
  def render(model) do
    {nodes, note} = select(model)
    alias_of = nodes |> Enum.with_index() |> Map.new(fn {n, i} -> {n.id, "s#{i}"} end)
    shown = Map.keys(alias_of) |> MapSet.new()

    lines =
      ["stateDiagram-v2"] ++
        if(note, do: ["    %% #{note}"], else: []) ++
        Enum.map(nodes, &~s(    state "#{label(&1)}" as #{alias_of[&1.id]})) ++
        for(n <- nodes, n.initial, do: "    [*] --> #{alias_of[n.id]}") ++
        for(
          e <- model.edges,
          MapSet.member?(shown, e.source) and MapSet.member?(shown, e.target),
          do: "    #{alias_of[e.source]} --> #{alias_of[e.target]} : #{e.action}"
        ) ++ highlight_lines(model.highlight, alias_of)

    Enum.join(lines, "\n") <> "\n"
  end

  defp select(%{nodes: nodes}) when length(nodes) <= @max, do: {nodes, nil}

  defp select(%{nodes: nodes, highlight: [_ | _] = highlight}) do
    wanted = MapSet.new(highlight)
    picked = Enum.filter(nodes, &MapSet.member?(wanted, &1.id)) |> Enum.take(@max)
    {picked, "truncated: showing #{length(picked)} highlighted of #{length(nodes)} states"}
  end

  defp select(%{nodes: nodes, edges: edges}) do
    by_id = Map.new(nodes, &{&1.id, &1})
    out = Enum.group_by(edges, & &1.source, & &1.target)
    start = nodes |> Enum.filter(& &1.initial) |> Enum.map(& &1.id)
    ids = bfs(start, out, MapSet.new(start), start)

    {Enum.map(ids, &by_id[&1]),
     "truncated: showing #{length(ids)} of #{length(nodes)} states (breadth-first from the initial states)"}
  end

  defp bfs(_frontier, _out, _seen, acc) when length(acc) >= @max, do: Enum.take(acc, @max)
  defp bfs([], _out, _seen, acc), do: acc

  defp bfs(frontier, out, seen, acc) do
    next =
      frontier
      |> Enum.flat_map(&Map.get(out, &1, []))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))

    bfs(next, out, MapSet.union(seen, MapSet.new(next)), acc ++ next)
  end

  defp highlight_lines([], _alias_of), do: []

  defp highlight_lines(highlight, alias_of) do
    aliases = highlight |> Enum.map(&alias_of[&1]) |> Enum.reject(&is_nil/1)

    if aliases == [],
      do: [],
      else: [
        "    classDef path stroke-width:3px,stroke:#d9480f",
        "    class #{Enum.join(aliases, ",")} path"
      ]
  end

  defp label(node) do
    node.vars
    |> Enum.sort()
    |> Enum.map_join("<br/>", fn {k, v} -> escape("#{k} = #{v}") end)
  end

  defp escape(text) do
    text
    |> String.replace("\"", "#quot;")
    |> String.replace("<", "#lt;")
    |> String.replace(">", "#gt;")
  end
end
