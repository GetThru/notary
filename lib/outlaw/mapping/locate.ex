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
        init_line: find_def_line(exprs, :init),
        actions_line: find_def_line(exprs, :actions),
        project_line: find_def_line(exprs, :project),
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

  defp find_def_line(exprs, name) do
    Enum.find_value(exprs, fn
      {:def, meta, [{^name, _, _args} | _]} -> Keyword.get(meta, :line)
      _ -> nil
    end)
  end

  defp find_action_lines(exprs) do
    exprs
    |> Enum.filter(&action_clause?/1)
    |> Enum.reduce(%{}, fn {:def, meta, [{:action, _, [first_arg | _]} | _]}, acc ->
      line = Keyword.get(meta, :line)

      case first_arg do
        literal when is_binary(literal) -> Map.put_new(acc, literal, line)
        _ -> Map.put_new(acc, "*", line)
      end
    end)
  end

  defp action_clause?({:def, _meta, [{:action, _, args} | _]}) when is_list(args),
    do: length(args) == 3

  defp action_clause?(_), do: false
end
