defmodule Outlaw.Report do
  @moduledoc "Renders Outlaw results as human-readable text and as JSON-ready maps."

  alias Outlaw.{Error, Value}
  alias Outlaw.Conformance.{Failure, Step}

  @type stage :: %{
          stage: :lock | :check | :conformance,
          status: :pass | :fail | :error | :skipped,
          payload: term()
        }
  @type spec_result :: %{spec: String.t(), status: :pass | :fail, stages: [stage()]}
  @type report :: %{status: :pass | :fail, lock: stage() | nil, specs: [spec_result()]}

  # -- text -------------------------------------------------------------------

  @spec format(report()) :: String.t()
  def format(%{lock: lock, specs: specs, status: status}) do
    lock_text =
      case lock do
        nil -> []
        %{status: :pass} -> ["lock: pass"]
        %{payload: {:error, %Error{} = e}} -> ["lock: FAIL", indent(e.message)]
      end

    spec_texts = Enum.map(specs, &format_spec/1)

    summary =
      if status == :pass, do: "Outlaw: all checks passed.", else: "Outlaw: verification FAILED."

    Enum.join(lock_text ++ spec_texts ++ [summary], "\n\n")
  end

  defp format_spec(%{spec: name, status: status, stages: stages}) do
    header = "#{name}: #{if status == :pass, do: "pass", else: "FAIL"}"
    Enum.join([header | Enum.map(stages, &format_stage(name, &1))], "\n")
  end

  defp format_stage(_name, %{stage: :check, payload: {:ok, stats}}),
    do: "  check: pass (#{stats.distinct_states} distinct states)"

  defp format_stage(_name, %{stage: stage, status: :skipped}), do: "  #{stage}: skipped"

  defp format_stage(_name, %{stage: :conformance, payload: {:ok, %{runs: runs, seed: seed}}}),
    do: "  conformance: pass (#{runs} runs, seed #{seed})"

  defp format_stage(name, %{stage: stage, status: status, payload: payload}) do
    body =
      case payload do
        {:violation, v} -> format_violation(name, v)
        {:error, %Failure{} = f} -> format_failure(name, f)
        {:error, %Error{} = e} -> e.message
      end

    "  #{stage}: #{status}\n" <> indent(body, 4)
  end

  @spec format_failure(String.t(), Failure.t()) :: String.t()
  def format_failure(spec_name, %Failure{} = f) do
    last = List.last(f.steps)
    rows = Enum.map(f.steps, &step_row(&1, &1 == last))
    width = rows |> Enum.map(fn {_, a, _, _, _} -> String.length(a) end) |> Enum.max(fn -> 6 end)

    table =
      Enum.map_join(rows, "\n", fn {i, action, outcome, state, mark} ->
        "  #{String.pad_trailing(i, 5)} #{String.pad_trailing(action, width)}  #{String.pad_trailing(outcome, 10)}  #{state}#{mark}"
      end)

    allowed =
      case last do
        nil ->
          []

        %Step{allowed: [], action: action} when is_binary(action) ->
          ["Spec allowed: (no #{action} transition is enabled here)"]

        %Step{allowed: allowed} ->
          ["Spec allowed: " <> Enum.map_join(allowed, " | ", &format_state/1)]
      end

    details = f.details |> Map.drop([:during]) |> Enum.map(fn {k, v} -> "#{k}: #{detail(v)}" end)
    during = if f.details[:during], do: ["During: #{f.details.during}"], else: []
    seed = if f.seed, do: " (seed #{f.seed})", else: ""

    reproduce =
      if f.seed,
        do: "mix outlaw.test #{spec_name} --seed #{f.seed}",
        else: "mix outlaw.test #{spec_name}"

    Enum.join(
      [
        "Conformance failure in #{spec_name}: #{f.kind}#{seed}",
        Failure.explanation(f.kind),
        "",
        "  step  action / params / outcome / implementation state",
        table,
        ""
      ] ++
        allowed ++
        during ++
        details ++
        [
          "",
          "Reproduce: #{reproduce}",
          "Visualize: mix outlaw.graph #{spec_name} --trace failure --open"
        ],
      "\n"
    )
  end

  defp step_row(%Step{} = s, last?) do
    action = if s.action, do: "#{s.action} #{inspect(s.params)}", else: "(init)"

    outcome =
      case s.outcome do
        :ok -> "ok"
        {:rejected, reason} -> "rejected #{inspect(reason)}"
      end

    {Integer.to_string(s.index), action, outcome, format_state(s.projection),
     if(last?, do: "   <-- diverges here", else: "")}
  end

  @spec format_violation(String.t(), map()) :: String.t()
  def format_violation(spec_name, v) do
    trace = Enum.map_join(v.trace, "\n", &trace_line/1)

    "TLC found a violation in #{spec_name}: #{v.message} (#{v.kind})\nCounterexample:\n#{trace}\n" <>
      "Visualize: mix outlaw.graph #{spec_name} --trace counterexample --open"
  end

  defp trace_line(%{stuttering: true, index: i}), do: "  #{i}. (stuttering forever)"
  defp trace_line(%{back_to: n, index: _}), do: "  -> loops back to state #{n}"

  defp trace_line(%{index: i, action: a, state: s}),
    do: "  #{i}. #{a || "(initial)"}  #{format_state(s)}"

  @spec format_state(map()) :: String.t()
  def format_state(state) when is_map(state),
    do: state |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k} = #{Value.to_tla(v)}" end)

  def format_state(other), do: inspect(other)

  defp detail(v) when is_binary(v), do: v
  defp detail(v), do: inspect(v)

  defp indent(text, n \\ 2),
    do: text |> String.split("\n") |> Enum.map_join("\n", &(String.duplicate(" ", n) <> &1))

  # -- JSON -------------------------------------------------------------------

  @spec to_json(report()) :: map()
  def to_json(%{status: status, lock: lock, specs: specs}) do
    %{
      "status" => Atom.to_string(status),
      "lock" => lock && stage_json(lock),
      "specs" =>
        Enum.map(specs, fn s ->
          %{
            "spec" => s.spec,
            "status" => Atom.to_string(s.status),
            "stages" => Enum.map(s.stages, &stage_json/1)
          }
        end)
    }
  end

  defp stage_json(%{stage: stage, status: status, payload: payload}) do
    Map.merge(
      %{"stage" => Atom.to_string(stage), "status" => Atom.to_string(status)},
      payload_json(payload)
    )
  end

  defp payload_json(:ok), do: %{}
  defp payload_json(:skipped), do: %{}

  defp payload_json({:ok, %{distinct_states: d, states_generated: g}}),
    do: %{"distinct_states" => d, "states_generated" => g}

  defp payload_json({:ok, %{runs: r, seed: s}}), do: %{"runs" => r, "seed" => s}
  defp payload_json({:violation, v}), do: %{"violation" => violation_json(v)}
  defp payload_json({:error, %Failure{} = f}), do: %{"failure" => failure_json(f)}
  defp payload_json({:error, %Error{} = e}), do: %{"error" => error_json(e)}

  defp violation_json(v) do
    %{
      "kind" => Atom.to_string(v.kind),
      "name" => v.name,
      "message" => v.message,
      "trace" =>
        Enum.map(v.trace, fn
          %{state: s} = step ->
            %{"index" => step.index, "action" => step.action, "state" => state_json(s)}

          %{back_to: n, index: i} ->
            %{"index" => i, "back_to" => n}

          %{stuttering: true, index: i} ->
            %{"index" => i, "stuttering" => true}
        end)
    }
  end

  defp failure_json(%Failure{} = f) do
    %{
      "kind" => Atom.to_string(f.kind),
      "explanation" => Failure.explanation(f.kind),
      "seed" => f.seed,
      "failed_step" => f.steps |> List.last() |> then(&(&1 && &1.index)),
      "steps" =>
        Enum.map(f.steps, fn s ->
          %{
            "index" => s.index,
            "action" => s.action,
            "params" => s.params && inspect(s.params),
            "outcome" =>
              if(s.outcome == :ok, do: "ok", else: "rejected: #{inspect(elem(s.outcome, 1))}"),
            "state" => state_json(s.projection),
            "spec_allowed" => Enum.map(s.allowed, &state_json/1)
          }
        end),
      "details" => jsonable(f.details)
    }
  end

  defp error_json(%Error{} = e),
    do: %{
      "kind" => Atom.to_string(e.kind),
      "message" => e.message,
      "details" => jsonable(e.details)
    }

  defp state_json(state) when is_map(state),
    do: Map.new(state, fn {k, v} -> {k, Value.to_tla(v)} end)

  defp state_json(other), do: inspect(other)

  defp jsonable(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable(v) when is_atom(v), do: Atom.to_string(v)
  defp jsonable(v), do: inspect(v)
end
