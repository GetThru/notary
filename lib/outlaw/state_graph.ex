defmodule Outlaw.StateGraph do
  @moduledoc """
  The reachable state graph of a spec, parsed from TLC's
  `-dump dot,actionlabels` output. State ids are TLC fingerprints (strings).
  """

  alias Outlaw.{Error, Value}

  defstruct states: %{}, edges: %{}, initial: [], actions: MapSet.new(), variables: []

  @type state_id :: String.t()
  @type t :: %__MODULE__{
          states: %{state_id() => %{String.t() => Value.t()}},
          edges: %{{state_id(), String.t()} => [state_id()]},
          initial: [state_id()],
          actions: MapSet.t(String.t()),
          variables: [String.t()]
        }

  @edge ~r/^(-?\d+) -> (-?\d+) \[label="((?:[^"\\]|\\.)*)"/
  @node ~r/^(-?\d+) \[label="(.*)"(,style = filled)?\];?$/

  @spec parse_dot(binary()) :: {:ok, t()} | {:error, Error.t()}
  def parse_dot(dot) when is_binary(dot) do
    dot
    |> String.split("\n")
    |> Enum.reduce_while({:ok, %__MODULE__{}}, fn line, {:ok, graph} ->
      case parse_line(String.trim(line), graph) do
        {:ok, graph} -> {:cont, {:ok, graph}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, graph} ->
        case finalize(graph) do
          {:ok, graph} -> {:ok, graph}
          {:error, _} = error -> error
        end

      error ->
        error
    end
  end

  defp parse_line(line, graph) do
    cond do
      match = Regex.run(@edge, line) ->
        [_, from, to, action] = match
        action = unescape(action)
        edges = Map.update(graph.edges, {from, action}, [to], &[to | &1])
        {:ok, %{graph | edges: edges, actions: MapSet.put(graph.actions, action)}}

      match = Regex.run(@node, line) ->
        [_, id, label | style] = match

        with {:ok, vars} <- parse_state(unescape(label)) do
          initial = if style == [], do: graph.initial, else: [id | graph.initial]
          {:ok, %{graph | states: Map.put(graph.states, id, vars), initial: initial}}
        end

      true ->
        {:ok, graph}
    end
  end

  # Every edge endpoint must be a defined node: `parse_line` silently skips
  # lines it doesn't recognize (so a node-line spelling drift in TLC's dump
  # would drop states while keeping edges), and a state missing here would
  # otherwise surface far away as a bare `Map.fetch!` KeyError from
  # `state/2` -- an error naming the state and the likely cause is owed
  # instead.
  defp finalize(graph) do
    edges =
      Map.new(graph.edges, fn {key, targets} ->
        {key, targets |> Enum.reverse() |> Enum.uniq()}
      end)

    missing =
      for {{from, _action}, targets} <- edges,
          id <- Enum.uniq([from | targets]),
          not Map.has_key?(graph.states, id),
          uniq: true do
        id
      end
      |> Enum.sort()

    case missing do
      [] ->
        variables =
          case Map.values(graph.states) do
            [first | _] -> first |> Map.keys() |> Enum.sort()
            [] -> []
          end

        {:ok, %{graph | edges: edges, initial: Enum.reverse(graph.initial), variables: variables}}

      ids ->
        {:error,
         Error.new(
           :unparseable_state,
           "The TLC dot dump defined edges to or from state#{plural(ids)} #{Enum.join(Enum.take(ids, 5), ", ")}," <>
             " but never those states' node lines" <>
             "#{if length(ids) > 5, do: " (#{length(ids)} in total)", else: ""}." <>
             " This usually means TLC's dot format changed; this is an Outlaw bug; please report it with the raw dump.",
           %{missing_states: ids, edges: map_size(edges), states: map_size(graph.states)}
         )}
    end
  end

  defp plural([_]), do: ""
  defp plural(_), do: "s"

  defp unescape(text) do
    Regex.replace(~r/\\(.)/s, text, fn
      _, "n" -> "\n"
      _, char -> char
    end)
  end

  @doc "Parses a TLC state: `/\\ var = value` lines, or a single `var = value`."
  @spec parse_state(String.t()) :: {:ok, %{String.t() => Value.t()}} | {:error, Error.t()}
  def parse_state(text) do
    text = String.trim(text)

    chunks =
      if String.starts_with?(text, "/\\ "),
        do: String.split(text, ~r/^\/\\ /m, trim: true),
        else: [text]

    Enum.reduce_while(chunks, {:ok, %{}}, fn chunk, {:ok, acc} ->
      chunk = String.trim(chunk)

      with [_, var, raw] <- Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*) = (.*)$/s, chunk),
           {:ok, value} <- Value.parse(raw) do
        {:cont, {:ok, Map.put(acc, var, value)}}
      else
        _ ->
          {:halt,
           {:error,
            Error.new(
              :unparseable_state,
              "Outlaw could not parse a TLC state. This is an Outlaw bug; please report it with the raw text.",
              %{raw: chunk}
            )}}
      end
    end)
  end

  @spec initial_states(t()) :: [state_id()]
  def initial_states(%__MODULE__{initial: initial}), do: initial

  @spec successors(t(), state_id(), String.t()) :: [state_id()]
  def successors(%__MODULE__{edges: edges}, id, action), do: Map.get(edges, {id, action}, [])

  @spec state(t(), state_id()) :: %{String.t() => Value.t()}
  def state(%__MODULE__{states: states}, id), do: Map.fetch!(states, id)

  @spec edges(t()) :: [{state_id(), String.t(), state_id()}]
  def edges(%__MODULE__{edges: edges}) do
    for {{from, action}, targets} <- Enum.sort(edges), to <- targets, do: {from, action, to}
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{states: states}), do: map_size(states)
end
