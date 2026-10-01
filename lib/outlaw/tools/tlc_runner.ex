defmodule Outlaw.Tools.TLCRunner do
  @moduledoc """
  Runs TLC as an OS process through a port. Enforces a wall-clock timeout and a
  distinct-state limit (read from TLC's progress and final stats lines); either
  one kills the OS process.
  """

  alias Outlaw.Error

  @type result :: %{exit_status: non_neg_integer(), output: String.t()}

  @spec run([String.t()], keyword()) :: {:ok, result()} | {:error, Error.t()}
  def run(tlc_args, opts) do
    java = Keyword.fetch!(opts, :java)
    jar = Keyword.fetch!(opts, :jar)
    timeout = Keyword.fetch!(opts, :timeout)
    max_states = Keyword.fetch!(opts, :max_states)
    cd = Keyword.get(opts, :cd, File.cwd!())
    jvm_args = tmp_dir_args(opts) ++ ["-XX:+UseParallelGC", "-cp", jar, "tlc2.TLC"]

    port =
      Port.open({:spawn_executable, java}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:line, 65_536},
        {:cd, cd},
        {:args, jvm_args ++ tlc_args}
      ])

    deadline = System.monotonic_time(:millisecond) + timeout

    loop(port, %{
      lines: [],
      partial: "",
      deadline: deadline,
      timeout: timeout,
      max_states: max_states
    })
  end

  defp loop(port, st) do
    remaining = max(st.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        loop(port, %{st | partial: st.partial <> chunk})

      {^port, {:data, {:eol, chunk}}} ->
        line = st.partial <> chunk
        st = %{st | lines: [line | st.lines], partial: ""}

        case distinct_states(line) do
          n when is_integer(n) and n > st.max_states ->
            kill(port)

            {:error,
             Error.new(
               :too_many_states,
               "TLC found more than #{st.max_states} distinct states (#{n} so far) and was stopped. " <>
                 "Use smaller CONSTANTS in the .cfg, or raise `config :outlaw, max_states: ...`.",
               %{distinct_states: n}
             )}

          _ ->
            loop(port, st)
        end

      {^port, {:exit_status, status}} ->
        {:ok, %{exit_status: status, output: output(st)}}
    after
      remaining ->
        kill(port)

        {:error,
         Error.new(:tlc_timeout, "TLC did not finish within #{st.timeout}ms and was stopped.", %{
           output_tail: st.lines |> Enum.take(20) |> Enum.reverse() |> Enum.join("\n")
         })}
    end
  end

  # TLC 1.7.4 extracts the standard modules (Naturals.tla, ...) bundled in the
  # jar into java.io.tmpdir and parses them there. Without this, two concurrent
  # JVMs sharing the OS-default java.io.tmpdir can overwrite/delete each
  # other's extracted copies mid-parse, producing an intermittent SANY
  # NullPointerException (surfaced to users as a confusing :spec_error). Each
  # run already gets its own unique :tmp_dir (TLC.ex's metadir); pointing
  # java.io.tmpdir at it gives each JVM its own extraction directory too.
  defp tmp_dir_args(opts) do
    case Keyword.get(opts, :tmp_dir) do
      nil -> []
      dir -> ["-Djava.io.tmpdir=#{dir}"]
    end
  end

  @spec distinct_states(String.t()) :: non_neg_integer() | nil
  def distinct_states(line) do
    case Regex.run(~r/([\d,]+) distinct states found/, line) do
      [_, n] -> n |> String.replace(",", "") |> String.to_integer()
      nil -> nil
    end
  end

  defp output(st), do: Enum.reverse([st.partial | st.lines]) |> Enum.join("\n")

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    Port.close(port)
    flush(port)
  catch
    _, _ -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
