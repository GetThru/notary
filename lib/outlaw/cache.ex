defmodule Outlaw.Cache do
  @moduledoc """
  Caches parsed state graphs in the work dir, keyed by the spec's contents, the
  TLA+ tools version and the cache format. Only passing TLC runs are cached.
  """

  alias Outlaw.{Config, Spec}

  @format "1"

  @spec key(Spec.t()) :: String.t()
  def key(%Spec{} = spec) do
    digest =
      :crypto.hash(:sha256, [Spec.content_hash(spec), Config.tla_version(), @format])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{spec.name}-#{digest}"
  end

  @spec path(String.t()) :: String.t()
  def path(key), do: Path.join(Config.work_dir(), key <> ".graph")

  @spec get(String.t()) :: {:ok, term()} | :miss
  def get(key) do
    case File.read(path(key)) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      {:error, _} -> :miss
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

    for old <- File.ls!(dir) || [] do
      old_path = Path.join(dir, old)

      if String.match?(old, pattern) && old_path != target do
        File.rm(old_path)
      end
    end

    tmp = target <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, :erlang.term_to_binary(value))
    File.rename!(tmp, target)
    :ok
  end
end
