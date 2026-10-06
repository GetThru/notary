defmodule Notary.TLC do
  @moduledoc "Runs TLC for a spec: model checking, DOT dumps, and the cached state graph."

  alias Notary.{Cache, Config, Error, Spec, StateGraph, Tools}
  alias Notary.TLC.Output
  alias Notary.Tools.TLCRunner

  @spec check(Spec.t(), keyword()) :: Output.result()
  def check(%Spec{} = spec, opts \\ []), do: run_tlc(spec, nil, opts)

  @spec dump(Spec.t(), String.t(), keyword()) :: Output.result()
  def dump(%Spec{} = spec, dot_path, opts \\ []), do: run_tlc(spec, Path.expand(dot_path), opts)

  @spec graph(Spec.t(), keyword()) ::
          {:ok, StateGraph.t(), Output.stats()}
          | {:violation, Output.violation()}
          | {:error, Error.t()}
  def graph(%Spec{} = spec, opts \\ []) do
    with {:ok, key} <- Cache.key(spec) do
      cached = if Keyword.get(opts, :force, false), do: :miss, else: Cache.get(key)

      case cached do
        {:ok, %{graph: graph, stats: stats}} -> {:ok, graph, stats}
        _ -> build_graph(spec, key, opts)
      end
    end
  end

  defp build_graph(spec, key, opts) when is_binary(key) do
    dot =
      Path.join([
        Config.work_dir(),
        "tmp",
        "#{spec.name}-#{System.unique_integer([:positive])}.dot"
      ])

    case File.mkdir_p(Path.dirname(dot)) do
      :ok ->
        try do
          with {:ok, stats} <- dump(spec, dot, opts),
               {:ok, dot_text} <- File.read(dot),
               {:ok, graph} <- StateGraph.parse_dot(dot_text) do
            :ok = Cache.put(key, %{graph: graph, stats: stats})
            {:ok, graph, stats}
          end
        after
          File.rm(dot)
        end

      {:error, reason} ->
        {:error,
         Error.new(:file_error, "Could not create #{Path.dirname(dot)}: #{inspect(reason)}")}
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

      case File.mkdir_p(metadir) do
        :ok ->
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

        {:error, reason} ->
          {:error, Error.new(:file_error, "Could not create #{metadir}: #{inspect(reason)}")}
      end
    end
  end

  defp dump_args(nil), do: []
  defp dump_args(path), do: ["-dump", "dot,actionlabels", path]
end
