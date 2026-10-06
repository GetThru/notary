defmodule Notary.Value do
  @moduledoc """
  Parses TLC's printed value syntax into Elixir terms and prints them back.

  | TLA+                              | Elixir                     |
  |-----------------------------------|----------------------------|
  | integers                          | integer                    |
  | `TRUE` / `FALSE`                  | `true` / `false`           |
  | `"str"`                           | binary                     |
  | model value `u1`                  | `{:model_value, "u1"}`     |
  | `{a, b}`                          | `MapSet`                   |
  | `<<a, b>>` (and functions on 1..n)| list                       |
  | `[f \|-> v]`                      | map with binary keys       |
  | `(k1 :> v1 @@ k2 :> v2)`          | map keyed by parsed keys   |

  Mapping modules return values in this representation from `project/1`.
  """

  @type t ::
          integer()
          | boolean()
          | binary()
          | {:model_value, binary()}
          | MapSet.t()
          | list()
          | map()

  @spec model(String.t()) :: {:model_value, String.t()}
  def model(name) when is_binary(name), do: {:model_value, name}

  @spec set(Enumerable.t()) :: MapSet.t()
  def set(enum), do: MapSet.new(enum)

  @doc """
  Finds the first value that is not in the Notary.Value representation,
  searching recursively into sets, lists, and map keys/values. Returns `nil`
  if `value` (and everything nested in it) is valid.
  """
  @spec invalid_leaf(term()) :: {:invalid, term()} | nil
  def invalid_leaf(v) when is_integer(v) or is_boolean(v) or is_binary(v), do: nil
  def invalid_leaf({:model_value, name}) when is_binary(name), do: nil
  def invalid_leaf(%MapSet{} = s), do: find_invalid(Enum.to_list(s))
  def invalid_leaf(list) when is_list(list), do: find_invalid(list)

  def invalid_leaf(map) when is_map(map) and not is_struct(map),
    do: find_invalid(Enum.flat_map(map, fn {k, v} -> [k, v] end))

  def invalid_leaf(other), do: {:invalid, other}

  defp find_invalid(items) do
    Enum.find_value(items, fn item -> invalid_leaf(item) end)
  end

  @doc "A short, human-readable name for the type of a value (for error hints)."
  @spec type_name(term()) :: String.t()
  def type_name(nil), do: "nil"
  def type_name(v) when is_atom(v), do: "atom"
  def type_name(v) when is_float(v), do: "float"
  def type_name(v) when is_tuple(v), do: "tuple"
  def type_name(v) when is_struct(v), do: "struct"
  def type_name(v) when is_function(v), do: "function"
  def type_name(v) when is_pid(v), do: "pid"
  def type_name(v) when is_reference(v), do: "reference"
  def type_name(_), do: "value"

  @spec parse(binary()) :: {:ok, t()} | {:error, {:unparseable_value, binary()}}
  def parse(raw) when is_binary(raw) do
    with {:ok, tokens} <- tokenize(raw, []),
         {:ok, value, []} <- parse_value(tokens) do
      {:ok, value}
    else
      _ -> {:error, {:unparseable_value, raw}}
    end
  end

  # -- tokenizer ------------------------------------------------------------

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\n, ?\t, ?\r], do: tokenize(rest, acc)
  defp tokenize("<<" <> rest, acc), do: tokenize(rest, [:lseq | acc])
  defp tokenize(">>" <> rest, acc), do: tokenize(rest, [:rseq | acc])
  defp tokenize("|->" <> rest, acc), do: tokenize(rest, [:maps_to | acc])
  defp tokenize(":>" <> rest, acc), do: tokenize(rest, [:colon_gt | acc])
  defp tokenize("@@" <> rest, acc), do: tokenize(rest, [:at_at | acc])
  defp tokenize("{" <> rest, acc), do: tokenize(rest, [:lbrace | acc])
  defp tokenize("}" <> rest, acc), do: tokenize(rest, [:rbrace | acc])
  defp tokenize("[" <> rest, acc), do: tokenize(rest, [:lbracket | acc])
  defp tokenize("]" <> rest, acc), do: tokenize(rest, [:rbracket | acc])
  defp tokenize("(" <> rest, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [:rparen | acc])
  defp tokenize("," <> rest, acc), do: tokenize(rest, [:comma | acc])

  defp tokenize("\"" <> rest, acc) do
    case read_string(rest, []) do
      {:ok, string, rest} -> tokenize(rest, [{:string, string} | acc])
      :error -> :error
    end
  end

  defp tokenize(<<c, _::binary>> = bin, acc) when c in ?0..?9 or c == ?- do
    case Integer.parse(bin) do
      {int, rest} -> tokenize(rest, [{:int, int} | acc])
      :error -> :error
    end
  end

  defp tokenize(<<c, _::binary>> = bin, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    [ident] = Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, bin)
    rest = binary_part(bin, byte_size(ident), byte_size(bin) - byte_size(ident))
    tokenize(rest, [ident_token(ident) | acc])
  end

  defp tokenize(_, _acc), do: :error

  defp ident_token("TRUE"), do: {:bool, true}
  defp ident_token("FALSE"), do: {:bool, false}
  defp ident_token(name), do: {:ident, name}

  defp read_string("\\\"" <> rest, acc), do: read_string(rest, [?" | acc])
  defp read_string("\\\\" <> rest, acc), do: read_string(rest, [?\\ | acc])
  defp read_string("\\n" <> rest, acc), do: read_string(rest, [?\n | acc])
  defp read_string("\\t" <> rest, acc), do: read_string(rest, [?\t | acc])

  defp read_string("\"" <> rest, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp read_string(<<c::utf8, rest::binary>>, acc), do: read_string(rest, [<<c::utf8>> | acc])
  defp read_string(_, _acc), do: :error

  # -- parser ---------------------------------------------------------------

  defp parse_value([{:int, i} | rest]), do: {:ok, i, rest}
  defp parse_value([{:string, s} | rest]), do: {:ok, s, rest}
  defp parse_value([{:bool, b} | rest]), do: {:ok, b, rest}
  defp parse_value([{:ident, name} | rest]), do: {:ok, {:model_value, name}, rest}
  defp parse_value([:lbrace, :rbrace | rest]), do: {:ok, MapSet.new(), rest}

  defp parse_value([:lbrace | rest]) do
    with {:ok, items, rest} <- parse_items(rest, :rbrace), do: {:ok, MapSet.new(items), rest}
  end

  defp parse_value([:lseq, :rseq | rest]), do: {:ok, [], rest}
  defp parse_value([:lseq | rest]), do: parse_items(rest, :rseq)

  defp parse_value([:lbracket | rest]) do
    with {:ok, pairs, rest} <- parse_fields(rest, []), do: {:ok, Map.new(pairs), rest}
  end

  defp parse_value([:lparen | rest]) do
    with {:ok, pairs, rest} <- parse_function(rest, []), do: {:ok, Map.new(pairs), rest}
  end

  defp parse_value(_), do: :error

  defp parse_items(tokens, close) do
    with {:ok, value, rest} <- parse_value(tokens) do
      case rest do
        [:comma | rest] ->
          with {:ok, values, rest} <- parse_items(rest, close), do: {:ok, [value | values], rest}

        [^close | rest] ->
          {:ok, [value], rest}

        _ ->
          :error
      end
    end
  end

  defp parse_fields([{:ident, key}, :maps_to | rest], acc) do
    with {:ok, value, rest} <- parse_value(rest) do
      case rest do
        [:comma | rest] -> parse_fields(rest, [{key, value} | acc])
        [:rbracket | rest] -> {:ok, Enum.reverse([{key, value} | acc]), rest}
        _ -> :error
      end
    end
  end

  defp parse_fields(_, _acc), do: :error

  defp parse_function(tokens, acc) do
    with {:ok, key, [:colon_gt | rest]} <- parse_value(tokens),
         {:ok, value, rest} <- parse_value(rest) do
      case rest do
        [:at_at | rest] -> parse_function(rest, [{key, value} | acc])
        [:rparen | rest] -> {:ok, Enum.reverse([{key, value} | acc]), rest}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  # -- printer --------------------------------------------------------------

  @spec to_tla(t()) :: String.t()
  def to_tla(true), do: "TRUE"
  def to_tla(false), do: "FALSE"
  def to_tla(int) when is_integer(int), do: Integer.to_string(int)
  def to_tla(string) when is_binary(string), do: quote_string(string)
  def to_tla({:model_value, name}), do: name
  def to_tla(%MapSet{} = set), do: "{" <> join(Enum.sort(set)) <> "}"
  def to_tla(list) when is_list(list), do: "<<" <> join(list) <> ">>"
  def to_tla(map) when is_map(map) and not is_struct(map) and map_size(map) == 0, do: "<<>>"

  def to_tla(map) when is_map(map) and not is_struct(map) do
    sorted = Enum.sort(map)

    if Enum.all?(Map.keys(map), &record_key?/1) do
      "[" <> Enum.map_join(sorted, ", ", fn {k, v} -> "#{k} |-> #{to_tla(v)}" end) <> "]"
    else
      "(" <> Enum.map_join(sorted, " @@ ", fn {k, v} -> "#{to_tla(k)} :> #{to_tla(v)}" end) <> ")"
    end
  end

  # Fallback for values outside the Notary.Value representation (nil, atoms,
  # floats, tuples, structs, ...). `to_tla/1` is used when rendering reports
  # and the viewer for failures whose mapping produced such a value (e.g. a
  # mistyped `project/1`), so it must never raise — see Notary.Conformance.Runner's
  # `:invalid_projection` check, which validates values before they get this far
  # in the normal case, and this fallback, which keeps rendering safe regardless.
  def to_tla(other), do: inspect(other)

  defp join(values), do: Enum.map_join(values, ", ", &to_tla/1)

  defp record_key?(key),
    do:
      is_binary(key) and key not in ["TRUE", "FALSE"] and
        Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key)

  defp quote_string(string) do
    escaped =
      string
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end
end
