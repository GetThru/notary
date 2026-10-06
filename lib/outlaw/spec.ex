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
    # Deduped: `mix outlaw.test Counter Counter` is a user slip, not a request
    # to model-check the spec twice and print duplicate report rows.
    names
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
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

  @spec content_hash(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def content_hash(%__MODULE__{} = spec) do
    # Only the spec's own module files plus `.cfg` -- not every `*.tla` in the
    # dir. A scratch module dropped into `specs/` (never referenced by the
    # spec) must not silently invalidate the cache key (and so force a full
    # TLC re-run). SANY only resolves modules the root module extends, and
    # those appears as `EXTENDS`/`INSTANCE` names -- hash the root module
    # `Name.tla` plus any sibling `X.tla` the root's text mentions.
    files = spec_files(spec)

    with :ok <- ensure_readable(files, spec) do
      hash =
        files
        |> Enum.map(fn file -> [Path.basename(file), 0, File.read!(file), 0] end)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, hash}
    end
  end

  # The spec's module file, its `.cfg`, and every sibling `.tla` the modules'
  # own text names via EXTENDS/INSTANCE (transitively; cycles are impossible
  # in a SANY-parseable spec). Standard modules (`EXTENDS Naturals`, ...) and
  # any referenced-but-missing module resolve from the jar / fail SANY's
  # parse elsewhere, so only files that actually exist are hashed. A scratch
  # module in `specs/` that nothing references is hashed by nothing.
  @spec_files_depth 10

  defp spec_files(%__MODULE__{dir: dir, tla_path: tla_path, cfg_path: cfg_path}) do
    root = Path.basename(tla_path)
    referenced = referenced_modules(tla_path, dir, MapSet.new([root]), @spec_files_depth)

    existing =
      referenced
      |> Enum.sort()
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.exists?/1)

    [tla_path, cfg_path] ++ existing
  end

  defp referenced_modules(tla_path, dir, seen, depth) when depth > 0 do
    case File.read(tla_path) do
      {:ok, text} ->
        names =
          Regex.scan(~r/\b(?:EXTENDS|INSTANCE)\s+([A-Za-z_][A-Za-z0-9_]*)/, text)
          |> Enum.map(fn [_, name] -> name <> ".tla" end)
          |> MapSet.new()

        Enum.reduce(Enum.to_list(names), seen, fn name, acc ->
          sibling = Path.join(dir, name)

          if MapSet.member?(acc, name) do
            acc
          else
            acc = MapSet.put(acc, name)

            if File.exists?(sibling) do
              referenced_modules(sibling, dir, acc, depth - 1)
            else
              acc
            end
          end
        end)

      # Unreadable root: `ensure_readable/2` below reports the error; here we
      # just fall back to the root file alone (the hash is moot on that path).
      {:error, _} ->
        seen
    end
  end

  defp referenced_modules(_tla_path, _dir, seen, _depth), do: seen

  # `File.read!/1` here would surface a typo'd `spec:` path (e.g. `use
  # Outlaw.Conformance, spec: "spec/Bank.tla"`) as a raw File.Error from
  # deep inside cache-key code. Only the root `.tla` and `.cfg` are required
  # (referenced siblings were filtered to existing ones above; a genuinely
  # missing one fails SANY's parse with its own `:spec_error`).
  defp ensure_readable(files, spec) do
    missing = Enum.reject(files, &File.exists?/1)

    if missing == [] do
      :ok
    else
      {:error,
       Error.new(
         :unknown_spec,
         "Spec #{spec.name} not found (looked for #{Enum.map_join(missing, ", ", &Path.relative_to_cwd/1)}). " <>
           "Check the `spec:` path in the mapping module's `use Outlaw.Conformance`."
       )}
    end
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

  @spec fair_actions(t()) :: {:ok, MapSet.t(String.t())} | {:error, Error.t()}
  def fair_actions(%__MODULE__{tla_path: tla_path}) do
    case File.read(tla_path) do
      {:ok, text} ->
        {:ok,
         text
         |> strip_comments()
         |> then(&Regex.scan(@fairness, &1))
         |> Enum.map(fn [_, name] -> name end)
         |> MapSet.new()}

      {:error, reason} ->
        {:error,
         Error.new(
           :unknown_spec,
           "Could not read #{Path.relative_to_cwd(tla_path)}: #{inspect(reason)}. " <>
             "Check the `spec:` path in the mapping module's `use Outlaw.Conformance`."
         )}
    end
  end

  @doc """
  Strips TLA comments (`\\* ...` to end of line, and `(* ... *)` blocks, which
  may span lines and nest) from `text`, replacing their characters with
  spaces rather than deleting them. Every character that isn't part of a
  comment keeps its original line and column, so callers that need source
  positions (such as `Outlaw.Spec.Locate`) can scan the result directly.
  Shared with `fair_actions/1` so there is one comment-stripping
  implementation.

  A single left-to-right pass over the text, tracking one of three states:
  plain text, inside a `(* ... *)` block (with its nesting depth), or inside
  a `"..."` string literal. This matters because the three can't be scanned
  independently: a `\\*` line comment is only a comment outside a block
  comment or a string (so an unbalanced `(*` *inside* a `\\* ...` comment must
  not start a real block comment that swallows the rest of the file), a block
  comment's own contents are never scanned for string literals, and a string
  literal's contents are never scanned for comment markers (`\\*`, `(*`,
  `*)`) at all.
  """
  @spec strip_comments(String.t()) :: String.t()
  def strip_comments(text) do
    text
    |> String.graphemes()
    |> scan(:normal, 0, [])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp scan([], _state, _depth, acc), do: acc

  # `(* ... *)` nests (`(* outer (* inner *) still outer *)`); recognized in
  # plain text and already inside a block comment, but not inside a string.
  defp scan(["(", "*" | rest], state, depth, acc) when state in [:normal, :block] do
    scan(rest, :block, depth + 1, [" ", " " | acc])
  end

  defp scan(["*", ")" | rest], :block, depth, acc) when depth > 1 do
    scan(rest, :block, depth - 1, [" ", " " | acc])
  end

  defp scan(["*", ")" | rest], :block, 1, acc) do
    scan(rest, :normal, 0, [" ", " " | acc])
  end

  # A `\* ...` line comment: only outside a block comment (inside one, `\*`
  # is just two ordinary characters) and only in plain text (a string's `\*`
  # isn't a comment either). Blanks straight through to (not including) the
  # next newline -- any `(*`/`*)` in there is just more blanked text, not a
  # block-comment delimiter, so an unterminated `(*` can't swallow anything
  # past this line.
  defp scan(["\\", "*" | rest], :normal, depth, acc) do
    scan_to_eol(rest, depth, [" ", " " | acc])
  end

  # A string literal's contents are copied through untouched -- not scanned
  # for comment markers -- up to and including its closing `"`. `\"` is an
  # escaped quote, not the closing one.
  defp scan(["\"" | rest], :normal, depth, acc) do
    scan_string(rest, depth, ["\"" | acc])
  end

  # Inside a block comment, every other character is blanked (newlines kept,
  # so line numbers downstream don't shift).
  defp scan([ch | rest], :block, depth, acc) do
    scan(rest, :block, depth, [blank(ch) | acc])
  end

  # Plain text otherwise: copied through unchanged.
  defp scan([ch | rest], state, depth, acc) do
    scan(rest, state, depth, [ch | acc])
  end

  defp scan_to_eol(["\n" | _] = rest, depth, acc), do: scan(rest, :normal, depth, acc)
  defp scan_to_eol([], depth, acc), do: scan([], :normal, depth, acc)
  defp scan_to_eol([ch | rest], depth, acc), do: scan_to_eol(rest, depth, [blank(ch) | acc])

  defp scan_string(["\\", ch | rest], depth, acc), do: scan_string(rest, depth, [ch, "\\" | acc])
  defp scan_string(["\"" | rest], depth, acc), do: scan(rest, :normal, depth, ["\"" | acc])
  defp scan_string([], depth, acc), do: scan([], :normal, depth, acc)
  defp scan_string([ch | rest], depth, acc), do: scan_string(rest, depth, [ch | acc])

  defp blank("\n"), do: "\n"
  defp blank(_), do: " "

  defp new(tla, cfg) do
    %__MODULE__{
      name: Path.basename(tla, ".tla"),
      dir: Path.dirname(tla),
      tla_path: tla,
      cfg_path: cfg
    }
  end
end
