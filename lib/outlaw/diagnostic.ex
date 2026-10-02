defmodule Outlaw.Diagnostic do
  @moduledoc """
  Builds compiler-style [pentiment](https://hex.pm/packages/pentiment)
  diagnostics for conformance failures (Outlaw design spec §9.1), pointing
  into the spec's `.tla` file (`Outlaw.Spec.Locate`) or the mapping module's
  own source (`Outlaw.Mapping.Locate`).

  `failure/2` returns `nil` whenever no source location can be found (an
  unparseable spec/mapping file, an action name the locator can't find, a
  mapping that doesn't expose `module_info(:compile)[:source]`, ...); callers
  fall back to the plain-text report in that case (no diagnostic, same text
  as before this feature).
  """

  alias Outlaw.Conformance.Failure
  alias Outlaw.Mapping.Locate, as: MappingLocate
  alias Outlaw.Spec
  alias Outlaw.Spec.Locate, as: SpecLocate
  alias Pentiment.{Label, Span}
  alias Pentiment.Report, as: PReport

  @type t :: {PReport.t(), sources :: map()}

  @doc """
  Builds a diagnostic for `failure`, or `nil` when nothing can be located.

  `opts`:
    * `:spec` (required) -- the `Outlaw.Spec.t()` the failure was found against.
    * `:mapping` -- the mapping module, or `nil` if unknown. Required for the
      kinds that point into the mapping's own source
      (`invalid_projection`, `invalid_action_result`, `timeout`, `crashed`);
      spec-only kinds (`action_not_enabled`, `illegal_transition`,
      `rejected_with_side_effect`, `init_mismatch`, `internal_action_stalled`)
      never need it. `exception` needs neither -- it uses the raw
      `{file, line}` frame the runner already captured.
  """
  @spec failure(Failure.t(), keyword()) :: t() | nil
  def failure(%Failure{} = f, opts) do
    spec = Keyword.fetch!(opts, :spec)
    mapping = Keyword.get(opts, :mapping)
    build(f, spec, mapping)
  end

  @doc "Renders a diagnostic built by `failure/2`, or `nil` straight through."
  @spec render(t() | nil, keyword()) :: String.t() | nil
  def render(nil, _opts), do: nil

  def render({%PReport{} = report, sources}, opts) do
    Pentiment.format(report, sources, colors: Keyword.get(opts, :colors, false))
  end

  # -- dispatch ---------------------------------------------------------------

  defp build(%Failure{kind: :action_not_enabled} = f, spec, _mapping),
    do: action_not_enabled(f, spec)

  defp build(%Failure{kind: :illegal_transition} = f, spec, _mapping),
    do: illegal_transition(f, spec)

  defp build(%Failure{kind: :rejected_with_side_effect} = f, spec, _mapping),
    do: rejected_with_side_effect(f, spec)

  defp build(%Failure{kind: :init_mismatch} = f, spec, _mapping), do: init_mismatch(f, spec)

  defp build(%Failure{kind: :internal_action_stalled} = f, spec, _mapping),
    do: internal_action_stalled(f, spec)

  defp build(%Failure{kind: :invalid_projection} = f, _spec, mapping),
    do: invalid_projection(f, mapping)

  defp build(%Failure{kind: :invalid_action_result} = f, _spec, mapping),
    do: invalid_action_result(f, mapping)

  defp build(%Failure{kind: :exception} = f, _spec, _mapping), do: exception(f)

  defp build(%Failure{kind: kind} = f, _spec, mapping) when kind in [:timeout, :crashed],
    do: during_based(f, mapping)

  defp build(_f, _spec, _mapping), do: nil

  # -- action_not_enabled -------------------------------------------------------

  defp action_not_enabled(f, spec) do
    with {:ok, rel, text} <- spec_source(spec),
         action when is_binary(action) <- List.last(f.steps).action,
         %{} = def_ <- SpecLocate.definition(text, action) do
      guards = Enum.filter(def_.conjuncts, &(&1.kind == :guard))
      message = guard_message(guards, pre_state(f))

      labels =
        case guards do
          [] -> [definition_fallback_label(def_, text, message)]
          _ -> Enum.map(guards, &conjunct_label(&1, :primary, message))
        end

      report =
        f
        |> base_report(rel)
        |> PReport.with_labels(labels)
        |> PReport.with_help("return {:rejected, reason, ctx}")

      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  defp guard_message([_one], state), do: "false here: #{format_state(state)}"
  defp guard_message([], state), do: "false here: #{format_state(state)}"
  defp guard_message(_several, state), do: "one of these is false in #{format_state(state)}"

  # -- illegal_transition -------------------------------------------------------

  defp illegal_transition(f, spec) do
    with {:ok, rel, text} <- spec_source(spec),
         action when is_binary(action) <- List.last(f.steps).action,
         %{} = def_ <- SpecLocate.definition(text, action) do
      effects = Enum.filter(def_.conjuncts, &(&1.kind == :effect))
      message = "implementation reached #{format_state(List.last(f.steps).projection)}"

      label =
        case effects do
          [] -> definition_fallback_label(def_, text, message)
          [one] -> conjunct_label(one, :primary, message)
          many -> merged_conjunct_label(many, :primary, message)
        end

      report =
        f
        |> base_report(rel)
        |> PReport.with_label(label)
        |> PReport.with_note(allowed_note(List.last(f.steps)))

      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  defp allowed_note(%{allowed: [], action: action}) when is_binary(action),
    do: "spec allowed: (no #{action} transition is enabled here)"

  defp allowed_note(%{allowed: allowed}),
    do: "spec allowed: " <> Enum.map_join(allowed, " | ", &format_state/1)

  # -- rejected_with_side_effect -------------------------------------------------

  defp rejected_with_side_effect(f, spec) do
    with {:ok, rel, text} <- spec_source(spec),
         action when is_binary(action) <- List.last(f.steps).action,
         %{} = def_ <- SpecLocate.definition(text, action) do
      pre = pre_state(f)
      post = List.last(f.steps).projection
      message = "rejected, but the state changed #{format_state(pre)} → #{format_state(post)}"
      label = name_label(def_, text, message)

      report = f |> base_report(rel) |> PReport.with_label(label)
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  # -- init_mismatch -------------------------------------------------------------

  defp init_mismatch(f, spec) do
    with {:ok, rel, text} <- spec_source(spec),
         %{} = def_ <- SpecLocate.definition(text, "Init") do
      step = List.first(f.steps)
      message = "implementation starts at #{format_state(step.projection)}"
      label = definition_label(def_, text, message)
      note = "spec's initial states: " <> Enum.map_join(step.allowed, " | ", &format_state/1)

      report = f |> base_report(rel) |> PReport.with_label(label) |> PReport.with_note(note)
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  # -- internal_action_stalled ----------------------------------------------------

  defp internal_action_stalled(f, spec) do
    with {:ok, rel, text} <- spec_source(spec) do
      labels = f.details |> Map.get(:pending, []) |> Enum.flat_map(&pending_labels(&1, text))

      case labels do
        [] -> nil
        _ -> {f |> base_report(rel) |> PReport.with_labels(labels), %{rel => text}}
      end
    else
      _ -> nil
    end
  end

  defp pending_labels(name, text) do
    def_label =
      case SpecLocate.definition(text, name) do
        nil -> []
        def_ -> [definition_label(def_, text, "#{name} never fired")]
      end

    occurrence_label =
      case SpecLocate.fairness(text, name) do
        nil ->
          []

        occ ->
          [
            span_label(
              occ.line,
              occ.column,
              occ.line,
              occ.end_column,
              :secondary,
              "fairness requires this to happen"
            )
          ]
      end

    def_label ++ occurrence_label
  end

  # -- invalid_projection ---------------------------------------------------------

  defp invalid_projection(f, mapping) do
    with {:ok, rel, text, loc} <- mapping_source(mapping),
         line when is_integer(line) <- loc.project_line do
      label = mapping_line_label(text, line, "project/1 defined here")
      help = projection_help(f.details)

      report = f |> base_report(rel) |> PReport.with_label(label) |> PReport.with_help(help)
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  defp projection_help(%{got: got, expected: expected}) when is_list(got) and is_list(expected) do
    "expected variables: #{Enum.join(expected, ", ")}; got: #{Enum.join(got, ", ")}"
  end

  defp projection_help(%{message: message}) when is_binary(message), do: message

  defp projection_help(_),
    do:
      "project/1 must return exactly the observed spec variables, in the Outlaw.Value representation"

  # -- invalid_action_result --------------------------------------------------------

  defp invalid_action_result(f, mapping) do
    with {:ok, rel, text, loc} <- mapping_source(mapping),
         {:ok, line} <- during_line(f.details[:during], loc) do
      label = mapping_line_label(text, line, during_message(f.details))
      report = f |> base_report(rel) |> PReport.with_label(label)
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  defp during_message(%{got: got}), do: "got: #{got}"
  defp during_message(_), do: nil

  # -- exception --------------------------------------------------------------------

  defp exception(f) do
    with {file, line} when is_binary(file) and is_integer(line) <- f.details[:frame],
         {:ok, text} <- File.read(file) do
      rel = Path.relative_to_cwd(file)
      label = mapping_line_label(text, line, "raised here")
      note = exception_note(f.details[:exception])

      report = f |> base_report(rel) |> PReport.with_label(label)
      report = if note, do: PReport.with_note(report, note), else: report
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  defp exception_note(nil), do: nil
  defp exception_note(text), do: text |> String.split("\n") |> List.first()

  # -- timeout / crashed --------------------------------------------------------------

  defp during_based(f, mapping) do
    with {:ok, rel, text, loc} <- mapping_source(mapping),
         {:ok, line} <- during_line(f.details[:during], loc) do
      label = mapping_line_label(text, line, during_based_message(f.kind))
      report = f |> base_report(rel) |> PReport.with_label(label)
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  defp during_based_message(:timeout), do: "timed out here"
  defp during_based_message(:crashed), do: "crashed here"

  defp during_line(during, loc) do
    case parse_during(during) do
      :init -> wrap(loc.init_line)
      :project -> wrap(loc.project_line)
      {:action, name} -> wrap(Map.get(loc.action_lines, name) || Map.get(loc.action_lines, "*"))
      :unknown -> :error
    end
  end

  defp wrap(nil), do: :error
  defp wrap(line), do: {:ok, line}

  defp parse_during(nil), do: :unknown
  defp parse_during("init/0"), do: :init
  defp parse_during("project/1"), do: :project
  defp parse_during("settle"), do: :project

  defp parse_during(during) do
    case Regex.run(~r/^action\/3\s+(\S+)/, during) do
      [_, name] -> {:action, name}
      _ -> :unknown
    end
  end

  # -- shared helpers -----------------------------------------------------------------

  defp base_report(f, source_rel) do
    PReport.error("Conformance failure: #{f.kind}")
    |> PReport.with_code(Atom.to_string(f.kind))
    |> PReport.with_source(source_rel)
  end

  defp pre_state(f), do: Enum.at(f.steps, -2).projection

  defp format_state(state), do: Outlaw.Report.format_state(state)

  defp spec_source(%Spec{tla_path: tla_path}) do
    case File.read(tla_path) do
      {:ok, text} -> {:ok, Path.relative_to_cwd(tla_path), text}
      {:error, _} -> :error
    end
  end

  defp mapping_source(nil), do: :error

  defp mapping_source(mapping) do
    with %{} = loc <- MappingLocate.locate(mapping),
         {:ok, text} <- File.read(loc.file) do
      {:ok, Path.relative_to_cwd(loc.file), text, loc}
    else
      _ -> :error
    end
  end

  defp conjunct_label(c, priority, message),
    do: span_label(c.line, c.column, c.end_line, c.end_column, priority, message)

  defp merged_conjunct_label(conjuncts, priority, message) do
    first = List.first(conjuncts)
    last = List.last(conjuncts)
    span_label(first.line, first.column, last.end_line, last.end_column, priority, message)
  end

  defp span_label(line, col, end_line, end_col, priority, message) do
    span = Span.position(line, col, end_line, end_col)

    cond do
      priority == :primary and line != end_line -> Label.bracket(span, message)
      priority == :primary -> Label.primary(span, message)
      true -> Label.secondary(span, message)
    end
  end

  # A definition's own name header, e.g. `Inc ==` or `Reset(x) ==` -- used
  # where the table points at "the action's name" rather than its body
  # (`rejected_with_side_effect`).
  defp name_label(def_, text, message) do
    line = text |> String.split("\n") |> Enum.at(def_.line - 1) || ""
    end_col = header_end_column(line, def_.column, def_.name)
    span_label(def_.line, def_.column, def_.line, end_col, :primary, message)
  end

  defp header_end_column(line, start_col, name) do
    rest = String.slice(line, start_col - 1, String.length(line))
    pattern = ~r/^#{Regex.escape(name)}(?:\([^)]*\))?\s*==/

    case Regex.run(pattern, rest) do
      [whole] -> start_col + String.length(whole)
      nil -> start_col + String.length(name)
    end
  end

  # A whole definition's label: its conjuncts merged if it has any, otherwise
  # a fallback span over its full text (`definition_fallback_label/3`) -- used
  # where the table points at "the definition" as a whole (`Init`, a pending
  # internal action).
  defp definition_label(def_, text, message) do
    case def_.conjuncts do
      [] -> definition_fallback_label(def_, text, message)
      conjuncts -> merged_conjunct_label(conjuncts, :primary, message)
    end
  end

  # A definition with no `/\` conjunct list (e.g. `Reset == x' = 0`): the
  # whole definition, from its name to the end of its last line.
  defp definition_fallback_label(def_, text, message) do
    lines = String.split(text, "\n")
    last_line = Enum.at(lines, def_.end_line - 1) || ""
    end_col = String.length(String.trim_trailing(last_line)) + 1
    span_label(def_.line, def_.column, def_.end_line, end_col, :primary, message)
  end

  # A mapping source line's full text, from its first non-blank character to
  # its last -- used for every mapping-pointing diagnostic, where
  # `Outlaw.Mapping.Locate` only gives a line number.
  defp mapping_line_label(text, line, message) do
    source_line = text |> String.split("\n") |> Enum.at(line - 1) || ""
    leading = source_line |> String.replace(~r/^(\s*).*/s, "\\1") |> String.length()
    end_col = String.length(String.trim_trailing(source_line)) + 1
    span_label(line, leading + 1, line, end_col, :primary, message)
  end
end
