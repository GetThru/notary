defmodule Outlaw.Mapping.Locate do
  @moduledoc """
  Pure source locator over a mapping module's own `.ex` file: the lines of
  its `use Outlaw.Conformance` call and of its `def init/0`, `def actions/0`,
  `def project/1` and `def action/3` clauses. Used to point pentiment
  diagnostics at the user's mapping module.

  Never raises: a module with no source, an unreadable or unparseable file,
  or any other odd input yields `nil`.
  """

  @type t :: %{
          file: String.t(),
          use_line: pos_integer() | nil,
          init_line: pos_integer() | nil,
          actions_line: pos_integer() | nil,
          project_line: pos_integer() | nil,
          action_lines: %{String.t() => pos_integer()}
        }

  @doc """
  Locates `module`'s mapping callbacks in its own compiled source file.
  """
  @spec locate(module()) :: t() | nil
  def locate(module) when is_atom(module) and not is_nil(module) do
    with {:ok, file} <- source_file(module),
         {:ok, source} <- read_file(file),
         {:ok, ast} <- parse(source),
         {:ok, body} <- find_module_body(ast, module) do
      exprs = body_exprs(body)

      %{
        file: file,
        use_line: find_use_line(exprs),
        init_line: find_def_line(exprs, :init, 0),
        actions_line: find_def_line(exprs, :actions, 0),
        project_line: find_def_line(exprs, :project, 1),
        action_lines: find_action_lines(exprs)
      }
    else
      :error -> nil
    end
  rescue
    _ -> nil
  end

  def locate(_), do: nil

  defp source_file(module) do
    case module.module_info(:compile)[:source] do
      nil -> :error
      source -> {:ok, to_string(source)}
    end
  rescue
    _ -> :error
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, source} -> {:ok, source}
      {:error, _} -> :error
    end
  end

  defp parse(source) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} -> {:ok, ast}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp find_module_body(ast, module) do
    case find_defmodule(ast, module) do
      nil -> :error
      body -> {:ok, body}
    end
  end

  defp find_defmodule({:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}, module) do
    if Module.concat(parts) == module, do: body
  end

  defp find_defmodule({:__block__, _meta, exprs}, module) do
    Enum.find_value(exprs, fn expr -> find_defmodule(expr, module) end)
  end

  defp find_defmodule(_, _), do: nil

  defp body_exprs({:__block__, _meta, exprs}), do: exprs
  defp body_exprs(expr), do: [expr]

  defp find_use_line(exprs) do
    Enum.find_value(exprs, fn
      {:use, meta, [{:__aliases__, _, parts} | _]} ->
        if Module.concat(parts) == Outlaw.Conformance, do: Keyword.get(meta, :line)

      _ ->
        nil
    end)
  end

  # Unwraps a `when`-guarded def head (`def name(args) when guard`) down to
  # its plain `{name, meta, args}` signature, so matching by name/arity works
  # the same whether or not the clause has a guard.
  defp def_signature({:when, _meta, [signature, _guard]}), do: signature
  defp def_signature(signature), do: signature

  defp find_def_line(exprs, name, arity) do
    Enum.find_value(exprs, fn
      {:def, meta, [head | _]} ->
        case def_signature(head) do
          {^name, _, args} -> if arity_matches?(args, arity), do: Keyword.get(meta, :line)
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp arity_matches?(nil, 0), do: true
  defp arity_matches?(args, arity) when is_list(args), do: length(args) == arity
  defp arity_matches?(_, _), do: false

  defp find_action_lines(exprs) do
    exprs
    |> Enum.reduce(%{}, fn expr, acc ->
      case action_def(expr) do
        {:ok, first_arg, line} ->
          key = if is_binary(first_arg), do: first_arg, else: "*"
          Map.put_new(acc, key, line)

        :error ->
          acc
      end
    end)
  end

  defp action_def({:def, meta, [head | _]}) do
    case def_signature(head) do
      {:action, _, args} when is_list(args) and length(args) == 3 ->
        [first_arg | _] = args
        {:ok, first_arg, Keyword.get(meta, :line)}

      _ ->
        :error
    end
  end

  defp action_def(_), do: :error
end
