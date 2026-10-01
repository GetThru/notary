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

  defp new(tla, cfg) do
    %__MODULE__{
      name: Path.basename(tla, ".tla"),
      dir: Path.dirname(tla),
      tla_path: tla,
      cfg_path: cfg
    }
  end
end
