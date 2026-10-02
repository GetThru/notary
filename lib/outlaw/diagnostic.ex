defmodule Outlaw.Diagnostic do
  @moduledoc """
  Builds compiler-style [pentiment](https://hex.pm/packages/pentiment)
  diagnostics for conformance failures (Outlaw design spec §9.1), pointing
  into the spec's `.tla` file (`Outlaw.Spec.Locate`) or the mapping module's
  own source (`Outlaw.Mapping.Locate`).

  `failure/2` and `error/2` return `nil` whenever no source location can be
  found (an unparseable spec/mapping file, an action name the locator can't
  find, a mapping that doesn't expose `module_info(:compile)[:source]`,
  ...); callers fall back to the plain-text report in that case (no
  diagnostic, same text as before this feature). `location/2` gives just the
  primary position (for `--json`'s `"location"` key) with the same fallback.
  """

  alias Outlaw.Conformance.Failure
  alias Outlaw.Error
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

  @doc """
  Builds a diagnostic for `error`, or `nil` when nothing can be located.

  Handles `:invalid_mapping` (points at the mapping's `use Outlaw.Conformance`
  line, with `def actions` as secondary and help built from the error's own
  message) and `:spec_error` (points at SANY's reported line/column in
  `<spec.dir>/<module>.tla`). Any other kind -- spec lock mismatches,
  Java/jar and TLC process errors -- returns `nil` (design spec §9.1: those
  keep their plain text form, with no source position).

  `opts`:
    * `:spec` -- the `Outlaw.Spec.t()` the error came from. Required for
      `:spec_error`; ignored for `:invalid_mapping`.
    * `:mapping` -- the mapping module. Required for `:invalid_mapping`;
      ignored for `:spec_error`.
  """
  @spec error(Error.t(), keyword()) :: t() | nil
  def error(%Error{} = e, opts) do
    spec = Keyword.get(opts, :spec)
    mapping = Keyword.get(opts, :mapping)
    build_error(e, spec, mapping)
  end

  @doc "Renders a diagnostic built by `failure/2`/`error/2`, or `nil` straight through."
  @spec render(t() | nil, keyword()) :: String.t() | nil
  def render(nil, _opts), do: nil

  def render({%PReport{} = report, sources}, opts) do
    Pentiment.format(report, sources, colors: Keyword.get(opts, :colors, false))
  end

  @doc """
  The primary source position for `failure_or_error` -- `%{file, line,
  column}` with `file` relative to the current working directory -- or `nil`
  when `failure/2`/`error/2` can't locate one. Used for `--json`'s
  `"location"` key. Never raises: built on top of `failure/2`/`error/2`, with
  the same safety net (a `nil` `:spec`/`:mapping` for a kind that needs one,
  or any other surprise, yields `nil` rather than crashing report rendering).
  """
  @spec location(Failure.t() | Error.t(), keyword()) ::
          %{file: String.t(), line: pos_integer(), column: pos_integer()} | nil
  def location(%Failure{} = f, opts) do
    f |> failure(opts) |> extract_location()
  rescue
    _ -> nil
  end

  def location(%Error{} = e, opts) do
    e |> error(opts) |> extract_location()
  rescue
    _ -> nil
  end

  defp extract_location(nil), do: nil

  defp extract_location({%PReport{labels: labels, source: source}, _sources}) do
    case Enum.find(labels, &Label.primary?/1) do
      nil ->
        nil

      label ->
        span = Label.resolved_span(label)
        %{file: source, line: span.start_line, column: span.start_column}
    end
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

  defp build_error(%Error{kind: :invalid_mapping} = e, _spec, mapping),
    do: invalid_mapping(e, mapping)

  defp build_error(%Error{kind: :spec_error} = e, spec, _mapping), do: spec_error(e, spec)

  defp build_error(_e, _spec, _mapping), do: nil

  # -- action_not_enabled -------------------------------------------------------

  defp action_not_enabled(f, spec) do
    with {:ok, rel, text} <- spec_source(spec),
         action when is_binary(action) <- List.last(f.steps).action,
         %{} = def_ <- SpecLocate.definition(text, action) do
      guards = Enum.filter(def_.conjuncts, &(&1.kind == :guard))
      state = pre_state(f)

      labels =
        case guards do
          [] ->
            [definition_fallback_label(def_, text, "not enabled in #{format_state(state)}")]

          [one] ->
            [conjunct_label(one, :primary, "false here: #{format_state(state)}")]

          several ->
            message = "one of these is false in #{format_state(state)}"
            Enum.map(several, &conjunct_label(&1, :primary, message))
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

  # -- illegal_transition -------------------------------------------------------

  defp illegal_transition(f, spec) do
    with {:ok, rel, text} <- spec_source(spec),
         action when is_binary(action) <- List.last(f.steps).action,
         %{} = def_ <- SpecLocate.definition(text, action) do
      effects = Enum.filter(def_.conjuncts, &(&1.kind == :effect))
      message = "implementation reached #{format_state(List.last(f.steps).projection)}"

      labels =
        case effects do
          [] -> [definition_fallback_label(def_, text, message)]
          _ -> Enum.map(effects, &conjunct_label(&1, :primary, message))
        end

      report =
        f
        |> base_report(rel)
        |> PReport.with_labels(labels)
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
      label = mapping_line_label(text, line, during_based_message(f.kind, f.details[:during]))
      report = f |> base_report(rel) |> PReport.with_label(label)
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  # A `:timeout` during settling points at `def project` (that's the only
  # mapping clause `during: "settle"` resolves to, see `during_line/2`), but
  # the real problem is quiescence -- some fair internal action never idling
  # -- not that `project/1` itself is slow. "timed out here" would misplace
  # the blame, so this case gets a softer message instead.
  defp during_based_message(:timeout, "settle"), do: "settling (polling project/1) timed out"
  defp during_based_message(:timeout, _during), do: "timed out here"
  defp during_based_message(:crashed, _during), do: "crashed here"

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

  # -- invalid_mapping (Outlaw.Error) ------------------------------------------------

  defp invalid_mapping(e, mapping) do
    with {:ok, rel, text, loc} <- mapping_source(mapping),
         line when is_integer(line) <- loc.use_line do
      label = mapping_line_label(text, line, "use Outlaw.Conformance here")

      report =
        error_base_report(:invalid_mapping, invalid_mapping_headline(e), rel)
        |> PReport.with_label(label)
        |> with_actions_label(loc, text)
        |> PReport.with_help(invalid_mapping_help(e))

      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  defp with_actions_label(report, %{actions_line: line}, text) when is_integer(line),
    do: PReport.with_label(report, mapping_line_label(text, line, "def actions", :secondary))

  defp with_actions_label(report, _loc, _text), do: report

  # The error's own message is `"Invalid mapping <module>:\n  <problem>\n  ..."`
  # (`Outlaw.Conformance.validate/2`) -- the first line (sans trailing `:`) is
  # a ready-made headline, and the rest (one problem per line, each indented
  # by the join) is the help text, flattened to a single line.
  defp invalid_mapping_headline(e), do: e.message |> first_line() |> String.trim_trailing(":")

  defp invalid_mapping_help(e) do
    e.message
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end

  # -- spec_error (SANY, via Outlaw.Error) ---------------------------------------------

  defp spec_error(e, spec) do
    with %Spec{dir: dir} <- spec,
         %{module: module, line: line, column: column} <- Map.get(e.details, :location),
         true <- is_binary(module),
         path = Path.join(dir, module <> ".tla"),
         {:ok, text} <- File.read(path) do
      rel = Path.relative_to_cwd(path)
      {message, note} = sany_message_and_note(e.details[:output])
      label = Label.primary(Span.position(line, column), message)

      report =
        error_base_report(:spec_error, message, rel)
        |> PReport.with_label(label)

      report = if note, do: PReport.with_note(report, note), else: report
      {report, %{rel => text}}
    else
      _ -> nil
    end
  end

  # SANY's output is already stripped of the "Parsing file"/"Semantic
  # processing of module" lines (`Outlaw.TLC.Output`) -- the first remaining
  # non-blank line is the message, the rest (if any) the note.
  defp sany_message_and_note(text) when is_binary(text) do
    case text |> String.split("\n") |> Enum.split_while(&(String.trim(&1) == "")) do
      {_blank, [first | rest]} ->
        note = rest |> Enum.join("\n") |> String.trim()
        {String.trim(first), if(note == "", do: nil, else: note)}

      {_all_blank, []} ->
        {"TLA+ spec error", nil}
    end
  end

  defp sany_message_and_note(_), do: {"TLA+ spec error", nil}

  defp first_line(text), do: text |> String.split("\n") |> List.first()

  defp error_base_report(kind, message, source_rel) do
    PReport.error(message)
    |> PReport.with_code(Atom.to_string(kind))
    |> PReport.with_source(source_rel)
  end

  # -- shared helpers -----------------------------------------------------------------

  defp base_report(f, source_rel) do
    PReport.error(headline(f))
    |> PReport.with_code(Atom.to_string(f.kind))
    |> PReport.with_source(source_rel)
  end

  # A short, descriptive first line -- the error code (`with_code/2` above)
  # still carries the bare kind (`error[action_not_enabled]: ...`), so this
  # is purely for a human skimming the header.
  defp headline(%Failure{kind: :action_not_enabled} = f) do
    action = List.last(f.steps).action || "the action"
    "#{action} was accepted, but the spec doesn't allow it in #{format_state(pre_state(f))}"
  end

  defp headline(%Failure{kind: :illegal_transition} = f) do
    action = List.last(f.steps).action || "the action"
    "#{action} reached a state the spec doesn't allow"
  end

  defp headline(%Failure{kind: :rejected_with_side_effect} = f) do
    action = List.last(f.steps).action || "the action"
    "#{action} was rejected, but the state changed"
  end

  defp headline(%Failure{kind: :init_mismatch}),
    do: "The initial state isn't one the spec allows"

  defp headline(%Failure{kind: :internal_action_stalled, details: details}) do
    case Map.get(details, :pending, []) do
      [one] ->
        "#{one} never happened, but the spec requires it (fairness)"

      [] ->
        "An internal action never happened, but the spec requires it (fairness)"

      several ->
        "#{Enum.join(several, ", ")} never happened, but the spec requires them (fairness)"
    end
  end

  defp headline(%Failure{kind: :invalid_projection}),
    do: "project/1 returned the wrong variables/values"

  defp headline(%Failure{kind: :invalid_action_result, details: details}) do
    label = during_display(details[:during])
    suffix = if Map.has_key?(details, :got), do: ": got #{details.got}", else: ""
    "#{label} returned an invalid result#{suffix}"
  end

  defp headline(%Failure{kind: :exception, details: details}) do
    action = during_action_name(details[:during])
    "#{action} raised #{exception_module(details[:exception])}"
  end

  defp headline(%Failure{kind: :timeout, details: details}) do
    "#{during_display(details[:during])} didn't return within #{details[:timeout]} ms"
  end

  defp headline(%Failure{kind: :crashed, details: details}) do
    "the implementation process crashed during #{during_display(details[:during])}"
  end

  defp headline(%Failure{kind: kind}), do: "Conformance failure: #{kind}"

  # The raw clause label as recorded in `details.during`, trimmed of any
  # trailing params blob (`"action/3 Inc %{}"` -> `"action/3 Inc"`) and with
  # `"settle"` spelled out -- used where the sentence is built around *which
  # callback* ran long/crashed (`timeout`, `crashed`, `invalid_action_result`).
  defp during_display(nil), do: "the implementation"
  defp during_display("settle"), do: "settling (project/1)"

  defp during_display(during) do
    case Regex.run(~r/^(action\/3\s+\S+|init\/0|project\/1)/, during) do
      [m | _] -> m
      nil -> during
    end
  end

  # The bare action name where one applies (`"action/3 Inc %{}"` -> `"Inc"`),
  # falling back to `during_display/1` otherwise -- used where the sentence
  # reads naturally with just the name as its subject (`exception`: "Inc
  # raised ...").
  defp during_action_name(during) do
    case during && Regex.run(~r/^action\/3\s+(\S+)/, during) do
      [_, name] -> name
      _ -> during_display(during)
    end
  end

  defp exception_module(nil), do: "an exception"

  defp exception_module(text) do
    case Regex.run(~r/^\*\* \(([^)]+)\)/, text) do
      [_, mod] -> mod
      _ -> "an exception"
    end
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

  # Underlines the conjunct's expression itself (`x < Max`), not its leading
  # `/\` connective and whitespace (`Outlaw.Spec.Locate`'s `expr_line`/
  # `expr_column`) -- `end_line`/`end_column` need no adjustment since
  # trailing whitespace is already trimmed there.
  defp conjunct_label(c, priority, message),
    do: span_label(c.expr_line, c.expr_column, c.end_line, c.end_column, priority, message)

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
  defp mapping_line_label(text, line, message, priority \\ :primary) do
    source_line = text |> String.split("\n") |> Enum.at(line - 1) || ""
    leading = source_line |> String.replace(~r/^(\s*).*/s, "\\1") |> String.length()
    end_col = String.length(String.trim_trailing(source_line)) + 1
    span_label(line, leading + 1, line, end_col, priority, message)
  end
end
