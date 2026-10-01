defmodule Outlaw.TLC do
  @moduledoc "Runs TLC for a spec: model checking, DOT dumps, and the cached state graph."

  alias Outlaw.{Cache, Config, Error, Spec, StateGraph, Tools}
  alias Outlaw.TLC.Output
  alias Outlaw.Tools.TLCRunner

  @spec check(Spec.t(), keyword()) :: Output.result()
  def check(%Spec{} = spec, opts \\ []), do: run_tlc(spec, nil, opts)

  @spec dump(Spec.t(), String.t(), keyword()) :: Output.result()
  def dump(%Spec{} = spec, dot_path, opts \\ []), do: run_tlc(spec, Path.expand(dot_path), opts)

  @spec graph(Spec.t(), keyword()) ::
          {:ok, StateGraph.t(), Output.stats()}
          | {:violation, Output.violation()}
          | {:error, Error.t()}
  def graph(%Spec{} = spec, opts \\ []) do
    key = Cache.key(spec)

    cached = if Keyword.get(opts, :force, false), do: :miss, else: Cache.get(key)

    case cached do
      {:ok, %{graph: graph, stats: stats}} -> {:ok, graph, stats}
      _ -> build_graph(spec, key, opts)
    end
  end

  defp build_graph(spec, key, opts) do
    dot =
      Path.join([
        Config.work_dir(),
        "tmp",
        "#{spec.name}-#{System.unique_integer([:positive])}.dot"
      ])

    File.mkdir_p!(Path.dirname(dot))

    try do
      with {:ok, stats} <- dump(spec, dot, opts),
           {:ok, graph} <- dot |> File.read!() |> StateGraph.parse_dot() do
        :ok = Cache.put(key, %{graph: graph, stats: stats})
        {:ok, graph, stats}
      end
    after
      File.rm(dot)
    end
  end

  defp run_tlc(spec, dot_path, opts) do
    with {:ok, tools} <- Tools.ensure_ready() do
      metadir =
        Path.join([
          Config.work_dir(),
          "tmp",
          "meta-#{spec.name}-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(metadir)

      args =
        ["-tool", "-workers", to_string(Config.get(:tlc_workers)), "-metadir", metadir] ++
          ["-config", Path.basename(spec.cfg_path)] ++
          dump_args(dot_path) ++ [Path.basename(spec.tla_path)]

      runner_opts = [
        java: tools.java,
        jar: tools.jar,
        cd: spec.dir,
        timeout: Keyword.get(opts, :timeout, Config.get(:tlc_timeout)),
        max_states: Keyword.get(opts, :max_states, Config.get(:max_states)),
        tmp_dir: metadir
      ]

      try do
        case TLCRunner.run(args, runner_opts) do
          {:ok, %{exit_status: status, output: output}} ->
            output |> Output.items() |> Output.interpret(status)

          {:error, _} = error ->
            error
        end
      after
        File.rm_rf(metadir)
      end
    end
  end

  defp dump_args(nil), do: []
  defp dump_args(path), do: ["-dump", "dot,actionlabels", path]
end
