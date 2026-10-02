defmodule Outlaw.Spec.Locate do
  @moduledoc """
  Pure source locators over a TLA+ spec's text: where a definition (and its
  guard/effect conjuncts) lives, and where a `WF_`/`SF_` fairness occurrence
  for a given action lives. Used to point pentiment diagnostics at the spec's
  `.tla` file.

  Both functions operate on comment-stripped text (`Outlaw.Spec.strip_comments/1`,
  which blanks comment characters without deleting them, so every remaining
  character keeps its original line and column). Neither function raises: odd
  or unparseable input yields `nil`.
  """

  alias Outlaw.Spec

  @type conjunct :: %{
          kind: :guard | :effect,
          line: pos_integer(),
          column: pos_integer(),
          end_line: pos_integer(),
          end_column: pos_integer(),
          text: String.t(),
          expr_line: pos_integer(),
          expr_column: pos_integer()
        }

  @type definition :: %{
          name: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          end_line: pos_integer(),
          conjuncts: [conjunct()]
        }

  @type fairness_occurrence :: %{
          line: pos_integer(),
          column: pos_integer(),
          end_column: pos_integer(),
          text: String.t()
        }

  @next_def_re ~r/^\s*[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s*==/
  @eq_sep_re ~r/^\s*={4,}\s*$/
  @dash_sep_re ~r/^\s*-{4,}\s*$/
  @prime_re ~r/[A-Za-z_][A-Za-z0-9_]*'/
  @fairness_prefix_re ~r/\b(?:WF|SF)_(?:<<[^>]*>>|[A-Za-z_][A-Za-z0-9_]*)\s*\(/
  @identifier_re ~r/^[A-Za-z_][A-Za-z0-9_]*/

  @doc """
  Finds `name ==` or `name(params) ==` at the start of a line (after optional
  leading whitespace) in `tla_text`, ignoring any occurrence inside a `\\*`
  line comment or a `(* ... *)` block comment. Returns `nil` if `name` isn't
  defined that way anywhere in the text.
  """
  @spec definition(String.t(), String.t()) :: definition() | nil
  def definition(tla_text, name) when is_binary(tla_text) and is_binary(name) and name != "" do
    lines = tla_text |> Spec.strip_comments() |> String.split("\n")
    header_re = ~r/^(\s*)#{Regex.escape(name)}(?![A-Za-z0-9_])(?:\([^)]*\))?\s*==/

    case find_header(lines, header_re) do
      nil ->
        nil

      {idx, ws, match_len} ->
        line_no = idx + 1
        column = String.length(ws) + 1
        stop_idx = find_stop_index(lines, idx)
        end_idx = trim_blank_backward(lines, stop_idx - 1, idx)

        conjuncts =
          case find_body_start(lines, idx, match_len, end_idx) do
            nil ->
              []

            {body_idx, body_col} ->
              case resolve_conjunct_list_start(lines, body_idx, body_col, end_idx) do
                nil -> []
                {list_idx, list_col} -> find_conjuncts(lines, list_idx, list_col, end_idx)
              end
          end

        %{name: name, line: line_no, column: column, end_line: end_idx + 1, conjuncts: conjuncts}
    end
  rescue
    _ -> nil
  end

  def definition(_, _), do: nil

  @doc """
  Finds the `WF_<sub>(...)` / `SF_<sub>(...)` occurrence in `tla_text` whose
  first identifier inside the outer parentheses is exactly `action_name`
  (matching `Outlaw.Spec.fair_actions/1`'s extraction rule). Returns `nil` if
  there is no such occurrence.
  """
  @spec fairness(String.t(), String.t()) :: fairness_occurrence() | nil
  def fairness(tla_text, action_name)
      when is_binary(tla_text) and is_binary(action_name) and action_name != "" do
    tla_text
    |> Spec.strip_comments()
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.find_value(fn {line, idx} -> find_fairness_in_line(line, action_name, idx) end)
  rescue
    _ -> nil
  end

  def fairness(_, _), do: nil

  # -- definition/2 helpers --------------------------------------------------

  defp find_header(lines, re) do
    lines
    |> Enum.with_index()
    |> Enum.find_value(fn {line, idx} ->
      case Regex.run(re, line) do
        [whole, ws] -> {idx, ws, String.length(whole)}
        _ -> nil
      end
    end)
  end

  defp find_stop_index(lines, start_idx) do
    total = length(lines)

    Enum.find((start_idx + 1)..(total - 1)//1, total, fn idx ->
      line = Enum.at(lines, idx)

      Regex.match?(@next_def_re, line) or Regex.match?(@eq_sep_re, line) or
        Regex.match?(@dash_sep_re, line)
    end)
  end

  defp trim_blank_backward(lines, idx, min_idx) do
    if idx > min_idx and String.trim(Enum.at(lines, idx)) == "" do
      trim_blank_backward(lines, idx - 1, min_idx)
    else
      idx
    end
  end

  defp find_body_start(lines, header_idx, match_len, end_idx) do
    skip_ws_from(lines, header_idx, match_len, end_idx)
  end

  # Skips forward from (idx, col) — which may be mid-line — to the next
  # non-blank character, scanning later lines if the rest of this one is
  # blank. Returns `{idx, col}` of that character, or `nil` if the body runs
  # out before one is found.
  defp skip_ws_from(lines, idx, col, end_idx) do
    line = Enum.at(lines, idx)
    remainder = String.slice(line, col, String.length(line) - col)

    case first_non_ws(remainder) do
      {offset, _ch} -> {idx, col + offset}
      nil -> find_first_nonblank(lines, idx + 1, end_idx)
    end
  end

  # If the body is `LET ... IN <list>`, the real conjunct list (if any) is
  # after the top-level `IN` — the one matching this `LET`, skipping over any
  # nested `LET ... IN` inside the bindings. Anything else is returned as-is.
  defp resolve_conjunct_list_start(lines, idx, col, end_idx) do
    case word_at(lines, idx, col) do
      "LET" ->
        case skip_let_in(lines, idx, col + String.length("LET"), end_idx, 1) do
          nil -> nil
          {in_idx, in_col} -> skip_ws_from(lines, in_idx, in_col, end_idx)
        end

      _ ->
        {idx, col}
    end
  end

  defp word_at(lines, idx, col) do
    line = Enum.at(lines, idx)
    tail = String.slice(line, col, String.length(line) - col)

    case Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, tail) do
      [word] -> word
      _ -> nil
    end
  end

  @let_in_re ~r/\b(?:LET|IN)\b/

  defp skip_let_in(lines, idx, col, end_idx, depth) do
    case find_keyword_after(lines, idx, col, end_idx) do
      nil ->
        nil

      {kidx, "LET", after_col} ->
        skip_let_in(lines, kidx, after_col, end_idx, depth + 1)

      {kidx, "IN", after_col} when depth == 1 ->
        {kidx, after_col}

      {kidx, "IN", after_col} ->
        skip_let_in(lines, kidx, after_col, end_idx, depth - 1)
    end
  end

  defp find_keyword_after(lines, start_idx, start_col, end_idx) do
    Enum.reduce_while(start_idx..end_idx, nil, fn idx, _ ->
      line = Enum.at(lines, idx)
      search_from = if idx == start_idx, do: start_col, else: 0
      tail = String.slice(line, search_from, String.length(line) - search_from)

      case Regex.run(@let_in_re, tail, return: :index) do
        [{rel_start, len}] ->
          col = search_from + rel_start
          {:halt, {idx, String.slice(line, col, len), col + len}}

        nil ->
          {:cont, nil}
      end
    end)
  end

  defp find_first_nonblank(_lines, idx, end_idx) when idx > end_idx, do: nil

  defp find_first_nonblank(lines, idx, end_idx) do
    case first_non_ws(Enum.at(lines, idx)) do
      {offset, _ch} -> {idx, offset}
      nil -> find_first_nonblank(lines, idx + 1, end_idx)
    end
  end

  defp first_non_ws(str) do
    str
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.find(fn {ch, _i} -> ch != " " and ch != "\t" end)
    |> case do
      {ch, i} -> {i, ch}
      nil -> nil
    end
  end

  defp find_conjuncts(lines, body_idx, body_col, end_idx) do
    if starts_with_and?(Enum.at(lines, body_idx), body_col) do
      item_indices =
        [body_idx] ++
          Enum.filter((body_idx + 1)..end_idx, fn i ->
            sibling_start?(Enum.at(lines, i), body_col)
          end)

      build_conjuncts(lines, item_indices, body_col, end_idx)
    else
      []
    end
  end

  # The body's own first line: the `/\` just needs to be at `col` (its
  # position was already derived as the first non-whitespace token there, so
  # whatever precedes it on the header line — the name, params and `==` —
  # isn't itself required to be blank).
  defp starts_with_and?(line, col) do
    String.length(line) >= col + 2 and String.slice(line, col, 2) == "/\\"
  end

  # A continuation line: only a sibling conjunct (not a nested one at deeper
  # indentation) if the `/\` sits at exactly `col` with nothing but
  # whitespace before it.
  defp sibling_start?(line, col) do
    starts_with_and?(line, col) and String.trim(String.slice(line, 0, col)) == ""
  end

  defp build_conjuncts(lines, item_indices, body_col, end_idx) do
    item_indices
    |> Enum.with_index()
    |> Enum.map(fn {start_idx, i} ->
      last_idx =
        case Enum.at(item_indices, i + 1) do
          nil -> end_idx
          next_start -> trim_blank_backward(lines, next_start - 1, start_idx)
        end

      last_line = Enum.at(lines, last_idx) |> String.trim_trailing()
      end_col = String.length(last_line)
      text = slice_span(lines, start_idx, body_col, last_idx, end_col)

      %{
        kind: classify(text),
        line: start_idx + 1,
        column: body_col + 1,
        end_line: last_idx + 1,
        end_column: end_col + 1,
        text: text,
        expr_line: start_idx + 1,
        expr_column: body_col + 1 + expr_offset(text)
      }
    end)
  end

  # The column offset (from the conjunct's own `column`, i.e. the `/\`) of
  # its expression's first non-blank character -- skipping the `/\` itself
  # and the whitespace after it, so a diagnostic can underline just `x < Max`
  # rather than `/\ x < Max`. `/\` always opens the conjunct's own first
  # line (see `starts_with_and?/2`), so only the first line of `text` matters.
  defp expr_offset(text) do
    first_line = text |> String.split("\n") |> List.first()
    rest = String.slice(first_line, 2, String.length(first_line) - 2)

    case first_non_ws(rest) do
      {offset, _ch} -> 2 + offset
      nil -> 2
    end
  end

  @string_literal_re ~r/"[^"]*"/
  @unchanged_re ~r/\bUNCHANGED\b/

  defp classify(text) do
    # A `'` inside a string literal (e.g. `/\ msg = "don't"`) isn't a primed
    # variable, so blank out string contents before checking.
    cleaned =
      Regex.replace(@string_literal_re, text, fn s -> String.duplicate(" ", String.length(s)) end)

    # `UNCHANGED x` has no literal prime but is semantically an effect (it
    # constrains x' = x) -- treat it as one so a diagnostic pointing at "what
    # changed" includes it.
    if Regex.match?(@prime_re, cleaned) or Regex.match?(@unchanged_re, cleaned),
      do: :effect,
      else: :guard
  end

  defp slice_span(lines, start_idx, start_col, end_idx, end_col) when start_idx == end_idx do
    Enum.at(lines, start_idx) |> String.slice(start_col, end_col - start_col)
  end

  defp slice_span(lines, start_idx, start_col, end_idx, end_col) do
    first_line = Enum.at(lines, start_idx)

    first =
      first_line
      |> String.slice(start_col, String.length(first_line) - start_col)
      |> String.trim_trailing()

    middle =
      for i <- (start_idx + 1)..(end_idx - 1)//1, do: String.trim_trailing(Enum.at(lines, i))

    last = Enum.at(lines, end_idx) |> String.slice(0, end_col) |> String.trim_trailing()

    Enum.join([first] ++ middle ++ [last], "\n")
  end

  # -- fairness/2 helpers -----------------------------------------------------

  defp find_fairness_in_line(line, action_name, idx) do
    @fairness_prefix_re
    |> Regex.scan(line, return: :index)
    |> Enum.find_value(fn [{start, len}] ->
      paren_pos = start + len - 1
      after_paren = String.slice(line, (paren_pos + 1)..-1//1)

      if leading_identifier(after_paren) == action_name do
        case matching_paren_end(line, paren_pos) do
          nil ->
            nil

          end_pos ->
            %{
              line: idx + 1,
              column: start + 1,
              end_column: end_pos + 2,
              text: String.slice(line, start, end_pos - start + 1)
            }
        end
      end
    end)
  end

  defp leading_identifier(str) do
    case str |> String.trim_leading() |> then(&Regex.run(@identifier_re, &1)) do
      [id] -> id
      _ -> nil
    end
  end

  defp matching_paren_end(line, open_pos) do
    chars = String.graphemes(line)
    do_match(chars, open_pos + 1, length(chars), 1)
  end

  defp do_match(_chars, pos, len, _depth) when pos >= len, do: nil

  defp do_match(chars, pos, len, depth) do
    case Enum.at(chars, pos) do
      "(" -> do_match(chars, pos + 1, len, depth + 1)
      ")" when depth == 1 -> pos
      ")" -> do_match(chars, pos + 1, len, depth - 1)
      _ -> do_match(chars, pos + 1, len, depth)
    end
  end
end
