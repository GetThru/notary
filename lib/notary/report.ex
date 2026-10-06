defmodule Notary.Report do
  @moduledoc "Renders Notary results as human-readable text and as JSON-ready maps."

  require Logger

  alias Notary.{Error, Value}
  alias Notary.Conformance.{Failure, Step}

  @type stage :: %{
          required(:stage) => :lock | :check | :conformance,
          required(:status) => :pass | :fail | :error | :skipped,
          required(:payload) => term(),
          optional(:internal) => [String.t()],
          optional(:fair) => [String.t()],
          optional(:spec) => Notary.Spec.t(),
          optional(:mapping) => module() | nil
        }
  @type spec_result :: %{spec: String.t(), status: :pass | :fail, stages: [stage()]}
  @type report :: %{status: :pass | :fail, lock: stage() | nil, specs: [spec_result()]}

  # -- text -------------------------------------------------------------------

  @spec format(report()) :: String.t()
  @spec format(report(), keyword()) :: String.t()
  def format(report, opts \\ [])

  def format(%{lock: lock, specs: specs, status: status}, opts) do
    colors = Keyword.get(opts, :colors, false)

    lock_text =
      case lock do
        nil -> []
        %{status: :pass} -> ["lock: pass"]
        %{payload: {:error, %Error{} = e}} -> ["lock: FAIL", indent(e.message)]
      end

    spec_texts = Enum.map(specs, &format_spec(&1, colors))

    summary =
      if status == :pass, do: "Notary: all checks passed.", else: "Notary: verification FAILED."

    Enum.join(lock_text ++ spec_texts ++ [summary], "\n\n")
  end

  defp format_spec(%{spec: name, status: status, stages: stages}, colors) do
    header = "#{name}: #{if status == :pass, do: "pass", else: "FAIL"}"
    Enum.join([header | Enum.map(stages, &format_stage(name, &1, colors))], "\n")
  end

  defp format_stage(_name, %{stage: :check, payload: {:ok, stats}}, _colors),
    do: "  check: pass (#{stats.distinct_states} distinct states)"

  defp format_stage(_name, %{stage: stage, status: :skipped}, _colors), do: "  #{stage}: skipped"

  defp format_stage(
         _name,
         %{stage: :conformance, payload: {:ok, %{runs: runs, seed: seed} = payload}} = stage,
         _colors
       ) do
    header = "  conformance: pass (#{runs} runs, seed #{seed}#{internal_suffix(stage)})"

    case payload do
      %{coverage: coverage} -> header <> "\n" <> format_coverage(coverage)
      _ -> header
    end
  end

  defp format_stage(name, %{stage: stage, status: status, payload: payload} = stage_map, colors) do
    body =
      case payload do
        {:violation, v} -> format_violation(name, v)
        {:error, %Failure{} = f} -> format_failure(name, f, stage_context(stage_map, colors))
        {:error, %Error{} = e} -> format_error(e, stage_context(stage_map, colors))
      end

    "  #{stage}: #{status}\n" <> indent(body, 4)
  end

  defp stage_context(stage_map, colors) do
    stage_map
    |> Map.take([:spec, :mapping])
    |> Map.to_list()
    |> Keyword.put(:colors, colors)
  end

  # Shows the mapping's declared internal actions on a conformance stage, with
  # a trailing `*` on the ones the spec marks fair (Notary.Spec.fair_actions/1,
  # design spec §4.3) -- e.g. "; internal: LimitKill, Reap*; * = fair". Empty
  # (or absent, for stages that never reached a mapping) renders nothing.
  defp internal_suffix(stage) do
    case Map.get(stage, :internal, []) do
      [] ->
        ""

      internal ->
        fair = Map.get(stage, :fair, [])
        names = internal |> Enum.sort() |> Enum.map_join(", ", &mark_fair(&1, fair))
        footnote = if Enum.any?(internal, &(&1 in fair)), do: "; * = fair", else: ""
        "; internal: #{names}#{footnote}"
    end
  end

  defp mark_fair(name, fair), do: if(name in fair, do: name <> "*", else: name)

  # Coverage line + gap warnings under a passing conformance stage (Notary
  # design spec §5.2). Gaps are warnings only -- they never change the
  # stage's `pass` status.
  defp format_coverage(%{actions: a, states: s, transitions: t}) do
    line =
      "    coverage: actions #{a.reached}/#{a.total}, " <>
        "observed states #{s.reached}/#{s.total}, transitions #{t.reached}/#{t.total}"

    [line, action_warning(a), state_warning(s)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp action_warning(%{unreached: []}), do: nil

  defp action_warning(%{unreached: unreached}),
    do: "    warning: never reached: #{Enum.join(unreached, ", ")}"

  defp state_warning(%{reached: reached, total: total}) when reached == total, do: nil

  defp state_warning(%{reached: reached, total: total, unreached: unreached}) do
    "    warning: #{total - reached} observed states never reached " <>
      "(first: #{format_state(List.first(unreached))})"
  end

  # An Notary.Error gets the same pentiment-diagnostic-before-legacy-text
  # treatment as a Failure (`format_failure/2` below) -- `:invalid_mapping`
  # and `:spec_error` are locatable (design spec §9.1); every other kind
  # falls straight through to the legacy text (no :spec/:mapping context, or
  # `Notary.Diagnostic.error/2` itself returns nil).
  defp format_error(%Error{} = e, context) do
    legacy = legacy_error_text(e)

    case error_diagnostic_text(e, context) do
      nil -> legacy
      diagnostic -> diagnostic <> "\n\n" <> legacy
    end
  end

  defp error_diagnostic_text(e, context) do
    case Keyword.get(context, :spec) do
      nil ->
        nil

      spec ->
        colors = Keyword.get(context, :colors, false)
        mapping = Keyword.get(context, :mapping)

        e
        |> Notary.Diagnostic.error(spec: spec, mapping: mapping)
        |> Notary.Diagnostic.render(colors: colors)
    end
  rescue
    # Same safety net as a Failure's diagnostic (see diagnostic_text/2) --
    # a bonus on top of the legacy report, never a reason to lose it.
    error ->
      Logger.warning(
        "Notary.Diagnostic failed to build/render an error diagnostic, falling back to plain text: " <>
          Exception.message(error)
      )

      nil
  end

  # Notary.Error.details can carry context that doesn't make it into `message`
  # (e.g. the last output lines on a TLC timeout, or the raw text behind an
  # unparseable value): spec §9 wants those in the human-readable report too,
  # not just in `--json`/`to_json/1`'s `details`.
  defp legacy_error_text(%Error{message: message, details: details}) do
    extras =
      [
        detail_block("Last output", details[:output_tail]),
        unless_in_message(message, "Output", details[:output]),
        detail_block("Raw text", details[:raw])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join([message | extras], "\n\n")
  end

  defp unless_in_message(message, label, text) when is_binary(text) do
    unless String.contains?(message, text), do: detail_block(label, text)
  end

  defp unless_in_message(_message, _label, _text), do: nil

  defp detail_block(label, text) when is_binary(text) and text != "",
    do: "#{label}:\n" <> indent(text, 2)

  defp detail_block(_label, _text), do: nil

  @spec format_failure(String.t(), Failure.t(), keyword()) :: String.t()
  def format_failure(spec_name, %Failure{} = f, context \\ []) do
    legacy = legacy_failure_text(spec_name, f)

    case diagnostic_text(f, context) do
      nil -> legacy
      diagnostic -> diagnostic <> "\n\n" <> legacy
    end
  end

  defp diagnostic_text(f, context) do
    case Keyword.get(context, :spec) do
      nil ->
        nil

      spec ->
        colors = Keyword.get(context, :colors, false)
        mapping = Keyword.get(context, :mapping)

        f
        |> Notary.Diagnostic.failure(spec: spec, mapping: mapping)
        |> Notary.Diagnostic.render(colors: colors)
    end
  rescue
    # A diagnostic is strictly a bonus on top of the legacy report: a bug in
    # a locator, a malformed Failure (e.g. empty steps), or any other
    # surprise while building/rendering it must never take down the report
    # itself -- fall back to no diagnostic (the plain legacy text), same as
    # an unlocatable source. Logged (not silently swallowed) so a broken
    # diagnostic layer is still visible somewhere.
    e ->
      Logger.warning(
        "Notary.Diagnostic failed to build/render a failure diagnostic, falling back to plain text: " <>
          Exception.message(e)
      )

      nil
  end

  defp legacy_failure_text(spec_name, %Failure{} = f) do
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

    details =
      f.details
      |> Map.drop([:during, :frame])
      |> Enum.map(fn {k, v} -> "#{k}: #{detail(v)}" end)

    during = if f.details[:during], do: ["During: #{f.details.during}"], else: []
    seed = if f.seed, do: " (seed #{f.seed})", else: ""

    reproduce =
      if f.seed,
        do: "mix notary.test #{spec_name} --seed #{f.seed}",
        else: "mix notary.test #{spec_name}"

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
          "Visualize: mix notary.graph #{spec_name} --trace failure --open"
        ],
      "\n"
    )
  end

  defp step_row(%Step{} = s, last?) do
    action =
      cond do
        is_nil(s.action) -> "(init)"
        is_nil(s.params) -> s.action
        true -> "#{s.action} #{inspect(s.params)}"
      end

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
      "Visualize: mix notary.graph #{spec_name} --trace counterexample --open"
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

  defp stage_json(%{stage: stage, status: status, payload: payload} = s) do
    extra =
      if stage == :conformance,
        do: conformance_extra_json(s, payload),
        else: %{}

    # Always carries :spec/:mapping (nil when the stage never had one) so
    # `Notary.Diagnostic.location/2` gets the same context the text report's
    # diagnostic does -- it safely yields nil for the kinds/stages that need
    # the missing piece, same as a stage with no location at all.
    context = [spec: Map.get(s, :spec), mapping: Map.get(s, :mapping)]

    %{"stage" => Atom.to_string(stage), "status" => Atom.to_string(status)}
    |> Map.merge(extra)
    |> Map.merge(payload_json(payload, context))
  end

  defp conformance_extra_json(s, payload) do
    base = %{"internal" => Map.get(s, :internal, []), "fair" => Map.get(s, :fair, [])}

    case payload do
      {:ok, %{coverage: coverage}} -> Map.put(base, "coverage", coverage_json(coverage))
      _ -> base
    end
  end

  defp coverage_json(%{actions: a, states: s, transitions: t}) do
    %{
      "actions" => %{"reached" => a.reached, "total" => a.total, "unreached" => a.unreached},
      "states" => %{
        "reached" => s.reached,
        "total" => s.total,
        "unreached" => Enum.map(s.unreached, &state_json/1)
      },
      "transitions" => %{
        "reached" => t.reached,
        "total" => t.total,
        "unreached" =>
          Enum.map(t.unreached, fn {from, action, to} ->
            %{"from" => state_json(from), "action" => action, "to" => state_json(to)}
          end)
      }
    }
  end

  defp payload_json(:ok, _context), do: %{}
  defp payload_json(:skipped, _context), do: %{}

  defp payload_json({:ok, %{distinct_states: d, states_generated: g}}, _context),
    do: %{"distinct_states" => d, "states_generated" => g}

  defp payload_json({:ok, %{runs: r, seed: s}}, _context), do: %{"runs" => r, "seed" => s}
  defp payload_json({:violation, v}, _context), do: %{"violation" => violation_json(v)}

  defp payload_json({:error, %Failure{} = f}, context),
    do: %{"failure" => failure_json(f, context)}

  defp payload_json({:error, %Error{} = e}, context), do: %{"error" => error_json(e, context)}

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

  defp failure_json(%Failure{} = f, context) do
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
      "details" => jsonable(Map.drop(f.details, [:frame]))
    }
    |> with_location_json(f, context)
  end

  defp error_json(%Error{} = e, context) do
    %{
      "kind" => Atom.to_string(e.kind),
      "message" => e.message,
      "details" => jsonable(e.details)
    }
    |> with_location_json(e, context)
  end

  # Adds `"location" => %{"file", "line", "column"}` (design spec §9.1) when
  # `Notary.Diagnostic.location/2` finds one for this failure/error in its
  # stage's :spec/:mapping context -- absent otherwise (no key change to
  # anything that already shipped).
  defp with_location_json(map, failure_or_error, context) do
    case Notary.Diagnostic.location(failure_or_error, context) do
      nil ->
        map

      %{file: file, line: line, column: column} ->
        Map.put(map, "location", %{"file" => file, "line" => line, "column" => column})
    end
  end

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
