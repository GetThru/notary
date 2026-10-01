defmodule Outlaw.Verify do
  @moduledoc "Runs Outlaw's verification stages and assembles reports (shared by the mix tasks)."

  alias Outlaw.{Conformance, Error, Lock, Report, Spec, TLC}
  alias Outlaw.Conformance.Failure

  @graph_opts [:force, :timeout, :max_states]
  @conformance_opts [:seed, :max_runs, :max_steps, :action_timeout]

  @spec lock_stage(String.t()) :: Report.stage()
  def lock_stage(dir) do
    case Lock.check(dir) do
      :ok -> stage(:lock, :pass, :ok)
      {:error, error} -> stage(:lock, :fail, {:error, error})
    end
  end

  @spec check_spec(Spec.t(), keyword()) :: Report.spec_result()
  def check_spec(%Spec{} = spec, opts \\ []) do
    stage =
      case TLC.check(spec, Keyword.take(opts, @graph_opts)) do
        {:ok, stats} -> stage(:check, :pass, {:ok, stats})
        {:violation, v} -> stage(:check, :fail, {:violation, v})
        {:error, error} -> stage(:check, :error, {:error, error})
      end

    spec_result(spec.name, [stage])
  end

  @spec test_spec(Spec.t(), %{String.t() => module()}, keyword()) :: Report.spec_result()
  def test_spec(%Spec{} = spec, mappings, opts \\ []) do
    stages =
      case TLC.graph(spec, Keyword.take(opts, @graph_opts)) do
        {:ok, graph, stats} ->
          [stage(:check, :pass, {:ok, stats}), conformance_stage(spec, graph, mappings, opts)]

        {:violation, v} ->
          [stage(:check, :fail, {:violation, v}), stage(:conformance, :skipped, :skipped)]

        {:error, error} ->
          [stage(:check, :error, {:error, error}), stage(:conformance, :skipped, :skipped)]
      end

    spec_result(spec.name, stages)
  end

  defp conformance_stage(spec, graph, mappings, opts) do
    case Map.fetch(mappings, spec.name) do
      :error ->
        stage(:conformance, :fail, {:error, missing_mapping(spec)}, %{internal: [], fair: []})

      {:ok, module} ->
        internal = Conformance.internal_actions(module)
        fair = Conformance.fair_internal_actions(module)
        extra = %{internal: internal, fair: fair}

        case Conformance.check(module, graph, Keyword.take(opts, @conformance_opts)) do
          {:ok, summary} ->
            stage(:conformance, :pass, {:ok, summary}, extra)

          {:error, %Failure{} = failure} ->
            write_failure_artifact(spec.name, graph, failure)
            stage(:conformance, :fail, {:error, failure}, extra)

          {:error, %Error{} = error} ->
            stage(:conformance, :error, {:error, error}, extra)
        end
    end
  end

  # Recording a failure artifact is a nice-to-have for `--trace failure`; if the
  # work dir can't be written to (full disk, read-only mount, blocked path), the
  # conformance failure itself must still be reported rather than crashing here.
  defp write_failure_artifact(name, graph, failure) do
    Outlaw.Viewer.write_failure(name, graph, failure)
    :ok
  rescue
    _ in [File.Error, ArgumentError] -> :ok
  end

  defp missing_mapping(spec) do
    rel = Path.relative_to_cwd(spec.tla_path)

    Error.new(
      :missing_mapping,
      "No mapping module for spec #{spec.name}. Create one under test/outlaw/ with " <>
        "`use Outlaw.Conformance, spec: \"#{rel}\"` (see `mix outlaw.new`)."
    )
  end

  @spec report(Report.stage() | nil, [Report.spec_result()]) :: Report.report()
  def report(lock, specs) do
    ok? = (lock == nil or lock.status == :pass) and Enum.all?(specs, &(&1.status == :pass))
    %{status: if(ok?, do: :pass, else: :fail), lock: lock, specs: specs}
  end

  defp spec_result(name, stages) do
    ok? = Enum.all?(stages, &(&1.status in [:pass, :skipped]))
    %{spec: name, status: if(ok?, do: :pass, else: :fail), stages: stages}
  end

  defp stage(name, status, payload, extra \\ %{}),
    do: Map.merge(%{stage: name, status: status, payload: payload}, extra)
end
