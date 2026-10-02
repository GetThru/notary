defmodule Outlaw.Spec do
  @moduledoc "A TLA+ spec: `Name.tla` with a sibling `Name.cfg` TLC model."

  alias Outlaw.{Config, Error}

  defstruct [:name, :dir, :tla_path, :cfg_path]

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          tla_path: String.t(),
          cfg_path: String.t()
        }

  @spec discover(String.t()) :: [t()]
  def discover(dir \\ Config.specs_dir()) do
    dir
    |> Path.expand()
    |> Path.join("*.tla")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn tla ->
      cfg = Path.rootname(tla) <> ".cfg"
      if File.exists?(cfg), do: [new(tla, cfg)], else: []
    end)
  end

  @spec fetch(String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def fetch(name, dir \\ Config.specs_dir()) do
    case Enum.find(discover(dir), &(&1.name == name)) do
      nil ->
        {:error,
         Error.new(
           :unknown_spec,
           "No spec named #{name} in #{dir} (expected #{name}.tla and #{name}.cfg)."
         )}

      spec ->
        {:ok, spec}
    end
  end

  @spec select([String.t()], String.t()) :: {:ok, [t()]} | {:error, Error.t()}
  def select([], dir), do: {:ok, discover(dir)}

  def select(names, dir) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case fetch(name, dir) do
        {:ok, spec} -> {:cont, {:ok, acc ++ [spec]}}
        error -> {:halt, error}
      end
    end)
  end

  @spec from_path(String.t()) :: t()
  def from_path(tla_path) do
    tla = Path.expand(tla_path)
    new(tla, Path.rootname(tla) <> ".cfg")
  end

  @spec content_hash(t()) :: String.t()
  def content_hash(%__MODULE__{} = spec) do
    files = Enum.sort(Path.wildcard(Path.join(spec.dir, "*.tla"))) ++ [spec.cfg_path]

    files
    |> Enum.map(fn file -> [Path.basename(file), 0, File.read!(file), 0] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Every action name the spec's text marks weakly or strongly fair: the first
  identifier inside the parentheses of each `WF_<sub>(...)` / `SF_<sub>(...)`
  occurrence, where `<sub>` is a plain identifier (`WF_vars(Reap)`) or a tuple
  of variables (`WF_<<x, y>>(Reap)`). `WF_vars(Pay(u))` and
  `\\A u \\in U : WF_vars(Pay(u))` both yield `"Pay"` — only the identifier
  immediately inside the outer parentheses is taken, so a call's own
  arguments are ignored. TLA comments (`\\*` to end of line, and `(* ... *)`
  blocks) are stripped first.

  This is a syntactic scan of the spec's text, not a semantic one: a name
  found here that is not actually a graph action (e.g. `WF_vars(Next)` --
  `Next` is the whole-step formula, not an edge label) is simply harmless
  wherever the result is used, since callers only care about its
  intersection with real action names (e.g. `Outlaw.Conformance`'s declared
  `internal:` actions).
  """
  @fairness ~r/\b(?:WF|SF)_(?:<<[^>]*>>|[A-Za-z_][A-Za-z0-9_]*)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)/

  @spec fair_actions(t()) :: MapSet.t(String.t())
  def fair_actions(%__MODULE__{tla_path: tla_path}) do
    tla_path
    |> File.read!()
    |> strip_comments()
    |> then(&Regex.scan(@fairness, &1))
    |> Enum.map(fn [_, name] -> name end)
    |> MapSet.new()
  end

  @doc """
  Strips TLA comments (`\\* ...` to end of line, and `(* ... *)` blocks, which
  may span lines) from `text`, replacing their characters with spaces rather
  than deleting them. Every character that isn't part of a comment keeps its
  original line and column, so callers that need source positions (such as
  `Outlaw.Spec.Locate`) can scan the result directly. Shared with
  `fair_actions/1` so there is one comment-stripping implementation.
  """
  @spec strip_comments(String.t()) :: String.t()
  def strip_comments(text) do
    text
    |> strip_block_comments()
    |> strip_line_comments()
  end

  # `(* ... *)` block comments nest (`(* outer (* inner *) still outer *)`),
  # so a non-greedy regex (which would stop at the first `*)`) isn't enough —
  # this tracks nesting depth instead, one character at a time.
  defp strip_block_comments(text) do
    text
    |> String.graphemes()
    |> strip_block_chars(0, [])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp strip_block_chars([], _depth, acc), do: acc

  defp strip_block_chars(["(", "*" | rest], depth, acc) do
    strip_block_chars(rest, depth + 1, [" ", " " | acc])
  end

  defp strip_block_chars(["*", ")" | rest], depth, acc) when depth > 0 do
    strip_block_chars(rest, depth - 1, [" ", " " | acc])
  end

  defp strip_block_chars([ch | rest], depth, acc) when depth > 0 do
    strip_block_chars(rest, depth, [blank(ch) | acc])
  end

  defp strip_block_chars([ch | rest], depth, acc) do
    strip_block_chars(rest, depth, [ch | acc])
  end

  defp blank("\n"), do: "\n"
  defp blank(_), do: " "

  defp strip_line_comments(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &blank_line_comment/1)
  end

  defp blank_line_comment(line) do
    case String.split(line, "\\*", parts: 2) do
      [before, comment] -> before <> String.duplicate(" ", String.length(comment) + 2)
      [before] -> before
    end
  end

  defp new(tla, cfg) do
    %__MODULE__{
      name: Path.basename(tla, ".tla"),
      dir: Path.dirname(tla),
      tla_path: tla,
      cfg_path: cfg
    }
  end
end
