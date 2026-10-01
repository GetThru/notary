defmodule Outlaw.TLC.Output do
  @moduledoc "Parses TLC `-tool` mode output into messages and interprets them."

  alias Outlaw.{Error, StateGraph}

  @type message :: %{code: integer(), severity: integer(), body: String.t()}
  @type item :: {:message, message()} | {:text, String.t()}
  @type step ::
          %{index: pos_integer(), action: String.t() | nil, state: map()}
          | %{index: pos_integer(), stuttering: true}
          | %{index: pos_integer(), back_to: pos_integer()}
  @type violation :: %{
          kind: :invariant | :deadlock | :liveness | :assertion | :property,
          name: String.t() | nil,
          message: String.t(),
          trace: [step()]
        }
  @type stats :: %{distinct_states: non_neg_integer(), states_generated: non_neg_integer()}
  @type result :: {:ok, stats()} | {:violation, violation()} | {:error, Error.t()}

  @start ~r/^@!@!@STARTMSG (\d+):(\d+) @!@!@$/
  @finish ~r/^@!@!@ENDMSG \d+ @!@!@$/

  @violations %{
    2107 => :invariant,
    2110 => :invariant,
    2108 => :property,
    2112 => :property,
    2114 => :deadlock,
    2116 => :liveness,
    2132 => :assertion
  }

  @spec items(binary()) :: [item()]
  def items(output) do
    {items, current} =
      output
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], nil}, fn line, {items, current} ->
        cond do
          match = Regex.run(@start, line) ->
            [_, code, severity] = match

            current = %{
              code: String.to_integer(code),
              severity: String.to_integer(severity),
              lines: []
            }

            {items, current}

          current != nil and Regex.match?(@finish, line) ->
            {[{:message, finish(current)} | items], nil}

          current != nil ->
            {items, %{current | lines: [line | current.lines]}}

          true ->
            {[{:text, line} | items], nil}
        end
      end)

    items = if current, do: [{:message, finish(current)} | items], else: items
    Enum.reverse(items)
  end

  defp finish(%{code: code, severity: severity, lines: lines}) do
    %{
      code: code,
      severity: severity,
      body: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing()
    }
  end

  @spec interpret([item()], integer()) :: result()
  def interpret(items, exit_status) do
    messages = for {:message, message} <- items, do: message

    cond do
      exit_status == 150 or sany_error?(items) -> {:error, spec_error(items)}
      violation = violation(messages) -> {:violation, violation}
      exit_status == 0 -> {:ok, stats(messages)}
      true -> {:error, tlc_failed(items, exit_status)}
    end
  end

  defp sany_error?(items) do
    Enum.any?(items, fn
      {:text, text} ->
        text =~ "***Parse Error***" or text =~ "*** Errors:" or text =~ "Could not parse module"

      _ ->
        false
    end)
  end

  defp spec_error(items) do
    text =
      items
      |> Enum.flat_map(fn
        {:text, text} -> [text]
        _ -> []
      end)
      |> Enum.reject(&(&1 =~ ~r/^(Parsing file|Semantic processing of module)/))
      |> Enum.join("\n")
      |> String.trim()

    location = location(text)

    where =
      case location do
        %{module: m, line: l, column: c} -> " in #{m}.tla:#{l}:#{c}"
        nil -> ""
      end

    Error.new(:spec_error, "TLA+ spec error#{where}:\n#{text}", %{
      output: text,
      location: location
    })
  end

  defp location(text) do
    cond do
      match = Regex.run(~r/line (\d+), col (\d+) to line \d+, col \d+ of module (\w+)/, text) ->
        [_, line, col, module] = match
        %{module: module, line: String.to_integer(line), column: String.to_integer(col)}

      match = Regex.run(~r/at line (\d+), column (\d+)/, text) ->
        [_, line, col] = match
        module = with [_, m] <- Regex.run(~r/Could not parse module (\w+)/, text), do: m
        %{module: module, line: String.to_integer(line), column: String.to_integer(col)}

      true ->
        nil
    end
  end

  defp violation(messages) do
    case Enum.find(messages, &Map.has_key?(@violations, &1.code)) do
      nil ->
        nil

      message ->
        %{
          kind: Map.fetch!(@violations, message.code),
          name: violation_name(message.body),
          message: String.trim(message.body),
          trace:
            messages
            |> Enum.filter(&(&1.code in [2216, 2217, 2218, 2122]))
            |> Enum.map(&trace_step/1)
        }
    end
  end

  defp violation_name(body) do
    case Regex.run(~r/(?:Invariant|[Pp]roperty) (\S+) is violated/, body) do
      [_, name] -> name
      nil -> nil
    end
  end

  defp trace_step(%{code: 2218, body: body}) do
    [_, index] = Regex.run(~r/^(\d+):/, body)
    %{index: String.to_integer(index), stuttering: true}
  end

  defp trace_step(%{code: 2122, body: body}) do
    [_, index] = Regex.run(~r/^(\d+):/, body)
    %{index: String.to_integer(index), back_to: String.to_integer(index)}
  end

  defp trace_step(%{body: body}) do
    {index, action, text} =
      case String.split(body, "\n", parts: 2) do
        [header, rest] ->
          case Regex.run(~r/^(\d+): <(.*)>$/, header) do
            [_, index, label] -> {String.to_integer(index), action_name(label), rest}
            nil -> {1, nil, body}
          end

        [only] ->
          {1, nil, only}
      end

    case StateGraph.parse_state(text) do
      {:ok, state} -> %{index: index, action: action, state: state}
      {:error, _} -> %{index: index, action: action, state: %{}, raw: text}
    end
  end

  defp action_name("Initial predicate"), do: nil
  defp action_name(label), do: label |> String.split(~r/[\s(]/, parts: 2) |> hd()

  defp stats(messages) do
    with %{body: body} <- Enum.find(messages, &(&1.code == 2199)),
         [_, generated, distinct] <-
           Regex.run(~r/([\d,]+) states generated, ([\d,]+) distinct states found/, body) do
      %{states_generated: to_int(generated), distinct_states: to_int(distinct)}
    else
      _ -> %{states_generated: 0, distinct_states: 0}
    end
  end

  defp to_int(text), do: text |> String.replace(",", "") |> String.to_integer()

  defp tlc_failed(items, exit_status) do
    tail =
      items
      |> Enum.map(fn
        {:text, text} -> text
        {:message, %{body: body}} -> body
      end)
      |> Enum.take(-40)
      |> Enum.join("\n")
      |> String.trim()

    Error.new(:tlc_failed, "TLC exited with status #{exit_status}:\n#{tail}", %{
      exit_status: exit_status,
      output: tail
    })
  end
end
