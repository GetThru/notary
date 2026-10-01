defmodule Outlaw.Lock do
  @moduledoc """
  Records hashes of the human-authored spec files in `specs/.outlaw.lock`.
  `mix outlaw.verify` fails when a spec changed since the human last ran
  `mix outlaw.lock`, which makes unreviewed spec edits (e.g. by an LLM) visible.
  """

  alias Outlaw.{Config, Error}

  @file_name ".outlaw.lock"

  @type change :: {:changed | :unlocked | :removed, String.t()}

  @spec path(String.t()) :: String.t()
  def path(dir \\ Config.specs_dir()), do: Path.join(dir, @file_name)

  @spec write(String.t()) :: {:ok, [String.t()]}
  def write(dir \\ Config.specs_dir()) do
    hashes = current(dir) |> Enum.sort()

    entries =
      Enum.map_join(hashes, ",\n", fn {file, hash} ->
        "    #{JSON.encode!(file)}: #{JSON.encode!(hash)}"
      end)

    File.write!(path(dir), "{\n  \"version\": 1,\n  \"files\": {\n#{entries}\n  }\n}\n")
    {:ok, Enum.map(hashes, &elem(&1, 0))}
  end

  @spec changes(String.t()) :: [change()]
  def changes(dir \\ Config.specs_dir()) do
    locked = read(dir)
    current = current(dir)

    changed = for {f, h} <- current, Map.has_key?(locked, f), locked[f] != h, do: {:changed, f}
    unlocked = for {f, _} <- current, not Map.has_key?(locked, f), do: {:unlocked, f}
    removed = for {f, _} <- locked, not Map.has_key?(current, f), do: {:removed, f}
    Enum.sort(changed ++ unlocked ++ removed)
  end

  @spec check(String.t()) :: :ok | {:error, Error.t()}
  def check(dir \\ Config.specs_dir()) do
    case changes(dir) do
      [] -> :ok
      changes -> {:error, Error.new(:spec_lock_mismatch, message(changes), %{changes: changes})}
    end
  end

  defp message(changes) do
    lines = Enum.map_join(changes, "\n", fn {kind, file} -> "  #{kind}: #{file}" end)

    """
    Spec files differ from specs/.outlaw.lock:
    #{lines}
    Specs are human-authored. If you are an LLM agent: do not edit specs; revert the change and ask the human.
    If you are the human and the change is intentional, run `mix outlaw.lock`.\
    """
  end

  defp current(dir) do
    for file <- Path.wildcard(Path.join(dir, "*.{tla,cfg}")), into: %{} do
      {Path.basename(file),
       file |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}
    end
  end

  defp read(dir) do
    case File.read(path(dir)) do
      {:ok, body} -> body |> JSON.decode!() |> Map.fetch!("files")
      {:error, :enoent} -> %{}
    end
  end
end
