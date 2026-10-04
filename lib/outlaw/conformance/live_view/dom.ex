if Code.ensure_loaded?(LazyHTML) do
  defmodule Outlaw.Conformance.LiveView.Dom do
    @moduledoc """
    Decodes the `data-outlaw-var` markup convention (design spec §8.5) from
    rendered HTML into a projection. Each element carries `data-outlaw-var`
    and exactly one of `data-outlaw-json` (built-in `JSON`; no null or
    floats; an empty object is the empty function `<<>>`, i.e. `[]`) or
    `data-outlaw-value` (TLC syntax, `Outlaw.Value.parse/1`).
    """

    @spec decode(String.t()) ::
            {:ok, %{String.t() => Outlaw.Value.t()}}
            | {:error, %{message: String.t(), variable: String.t() | nil}}
    def decode(html) when is_binary(html) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-outlaw-var]")
      |> LazyHTML.attributes()
      |> Enum.reduce_while({:ok, %{}}, fn attrs, {:ok, acc} ->
        attrs = Map.new(attrs)
        name = attrs["data-outlaw-var"]

        with {:ok, value} <- value(name, attrs),
             :ok <- no_conflict(acc, name, value) do
          {:cont, {:ok, Map.put(acc, name, value)}}
        else
          {:error, message} -> {:halt, {:error, %{variable: name, message: message}}}
        end
      end)
    end

    defp value(name, %{"data-outlaw-json" => raw} = attrs)
         when not is_map_key(attrs, "data-outlaw-value") do
      with {:ok, decoded} <- json(raw),
           :ok <- json_supported(decoded, raw) do
        {:ok, empty_maps_to_sequences(decoded)}
      else
        _ ->
          {:error,
           "#{inspect(name)}: data-outlaw-json is not usable JSON (no null or floats): #{raw}"}
      end
    end

    defp value(name, %{"data-outlaw-value" => raw} = attrs)
         when not is_map_key(attrs, "data-outlaw-json") do
      case Outlaw.Value.parse(raw) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, "#{inspect(name)}: data-outlaw-value is not a TLA+ value: #{raw}"}
      end
    end

    defp value(name, _attrs),
      do: {:error, "#{inspect(name)}: needs exactly one of data-outlaw-json or data-outlaw-value"}

    # TLC prints an empty function as `<<>>`, which `Outlaw.Value` parses to
    # `[]`; an empty JSON object must be the same value or it can never match.
    defp empty_maps_to_sequences(map) when map == %{}, do: []

    defp empty_maps_to_sequences(map) when is_map(map),
      do: Map.new(map, fn {k, v} -> {k, empty_maps_to_sequences(v)} end)

    defp empty_maps_to_sequences(list) when is_list(list),
      do: Enum.map(list, &empty_maps_to_sequences/1)

    defp empty_maps_to_sequences(v), do: v

    defp json(raw) do
      {:ok, JSON.decode!(raw)}
    rescue
      _ -> :error
    end

    defp json_supported(v, _raw) when is_binary(v) or is_integer(v) or is_boolean(v), do: :ok
    defp json_supported(list, raw) when is_list(list), do: all_supported(list, raw)
    defp json_supported(map, raw) when is_map(map), do: all_supported(Map.values(map), raw)
    defp json_supported(_, _raw), do: :error

    defp all_supported(values, raw),
      do: if(Enum.all?(values, &(json_supported(&1, raw) == :ok)), do: :ok, else: :error)

    defp no_conflict(acc, name, value) do
      case Map.fetch(acc, name) do
        :error ->
          :ok

        {:ok, ^value} ->
          :ok

        {:ok, other} ->
          {:error,
           "#{inspect(name)} is rendered twice with different values: " <>
             "#{Outlaw.Value.to_tla(other)} and #{Outlaw.Value.to_tla(value)}"}
      end
    end
  end
end
