defmodule Notary.Cache do
  @moduledoc """
  Caches parsed state graphs in the work dir, keyed by the spec's contents, the
  TLA+ tools version and the cache format. Only passing TLC runs are cached.
  """

  alias Notary.{Config, Spec}

  @format "1"

  # `binary_to_term/2` with `:safe` refuses to create atoms missing from this
  # VM's atom table; a graph term never carries user-data atoms (state
  # variables become `Notary.Value` structs, action names are strings), so
  # `:safe` costs nothing and closes the atom-table-growth vector. A corrupt
  # or drift-affected file raises ArgumentError, which `get/1` reports as a
  # `:miss` (self-healing via a fresh TLC run), same as today.
  @graph_marker {:notary_cache, "1", :state_graph}

  @spec key(Spec.t()) :: {:ok, String.t()} | {:error, Notary.Error.t()}
  def key(%Spec{} = spec) do
    with {:ok, hash} <- Spec.content_hash(spec) do
      digest =
        :crypto.hash(:sha256, [hash, Config.tla_version(), @format])
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      {:ok, "#{spec.name}-#{digest}"}
    end
  end

  @spec path(String.t()) :: String.t()
  def path(key), do: Path.join(Config.work_dir(), key <> ".graph")

  @spec get(String.t()) :: {:ok, term()} | :miss
  def get(key) do
    case File.read(path(key)) do
      {:ok, binary} ->
        term = :erlang.binary_to_term(binary, [:safe])

        case term do
          %{@graph_marker => true, graph: graph, stats: stats}
          when is_map(graph) and is_map(stats) ->
            {:ok, %{graph: graph, stats: stats}}

          _ ->
            # A well-formed term of the wrong shape (written by an older
            # Notary whose %StateGraph{} differed): treat as a miss so the
            # graph is rebuilt, instead of failing far downstream.
            :miss
        end

      {:error, _} ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(String.t(), term()) :: :ok
  def put(key, value) do
    target = path(key)
    File.mkdir_p!(Path.dirname(target))

    # Extract spec name by removing the trailing "-<16 hex>" suffix
    name = String.slice(key, 0..-18//1)
    pattern = ~r/^#{Regex.escape(name)}-[0-9a-f]{16}\.graph$/

    dir = Path.dirname(target)

    for old <- File.ls!(dir) do
      old_path = Path.join(dir, old)

      if String.match?(old, pattern) && old_path != target do
        File.rm(old_path)
      end
    end

    tmp = target <> ".tmp#{System.unique_integer([:positive])}"

    binary =
      case value do
        %{graph: _, stats: _} = entry ->
          entry |> Map.put(@graph_marker, true) |> :erlang.term_to_binary()

        # Non-graph values (tests): stored as-is, `get/1` treats them as a
        # miss since they don't match the graph entry shape.
        other ->
          :erlang.term_to_binary(other)
      end

    File.write!(tmp, binary)
    File.rename!(tmp, target)
    :ok
  end
end
