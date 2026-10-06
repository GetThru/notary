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

    # Atomic (tmp + rename), like `Outlaw.Cache.put/2`: a crash mid-write
    # must never leave a truncated lock behind.
    target = path(dir)
    tmp = target <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, "{\n  \"version\": 1,\n  \"files\": {\n#{entries}\n  }\n}\n")
    File.rename!(tmp, target)
    {:ok, Enum.map(hashes, &elem(&1, 0))}
  end

  @spec changes(String.t()) :: [change()]
  def changes(dir \\ Config.specs_dir()) do
    case read(dir) do
      {:ok, locked} -> changes_from(locked, dir)
      {:error, error} -> raise error
    end
  end

  # Computes changes against an already-decoded lock map, so `check/1` reads
  # the lock file once: `read/1` twice (once here, once via `changes/1`)
  # would race a concurrent edit/corruption between the reads and turn the
  # promised `{:error, :spec_lock_corrupt}` result into a raise.
  defp changes_from(locked, dir) do
    current = current(dir)

    changed = for {f, h} <- current, Map.has_key?(locked, f), locked[f] != h, do: {:changed, f}
    unlocked = for {f, _} <- current, not Map.has_key?(locked, f), do: {:unlocked, f}
    removed = for {f, _} <- locked, not Map.has_key?(current, f), do: {:removed, f}
    Enum.sort(changed ++ unlocked ++ removed)
  end

  @spec check(String.t()) :: :ok | {:error, Error.t()}
  def check(dir \\ Config.specs_dir()) do
    case read(dir) do
      {:ok, locked} ->
        case changes_from(locked, dir) do
          [] ->
            :ok

          changes ->
            {:error, Error.new(:spec_lock_mismatch, message(changes), %{changes: changes})}
        end

      {:error, error} ->
        {:error, error}
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
    lock_path = path(dir)

    case File.read(lock_path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, json} ->
            case json do
              %{"files" => files} when is_map(files) ->
                {:ok, files}

              _ ->
                {:error,
                 Error.new(:spec_lock_corrupt, corrupt_message(lock_path), %{path: lock_path})}
            end

          {:error, _} ->
            {:error,
             Error.new(:spec_lock_corrupt, corrupt_message(lock_path), %{path: lock_path})}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} ->
        {:error, Error.new(:spec_lock_corrupt, corrupt_message(lock_path), %{path: lock_path})}
    end
  end

  defp corrupt_message(lock_path) do
    """
    Spec lock file is corrupt or inaccessible: #{lock_path}
    If you are an LLM agent: do not edit or regenerate the lock; ask the human.
    If you are the human, run `mix outlaw.lock` to rewrite it.\
    """
  end
end
