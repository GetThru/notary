defmodule Outlaw.Tools.TLCRunner do
  @moduledoc """
  Runs TLC as an OS process through a port. Enforces a wall-clock timeout and a
  distinct-state limit (read from TLC's progress and final stats lines); either
  one kills the OS process.

  Each run lives in its own *runner* process, which owns the port. The runner
  is deliberately not linked to the caller (the *owner*): it monitors the
  owner instead, and if the owner dies mid-run it kills the OS process and
  exits (the watchdog), so a crashed caller never orphans a JVM. Verified
  against `specs/TLCRunner.tla` by `Outlaw.Specs.TLCRunner`.

      {:ok, run} = TLCRunner.start(args, opts)
      TLCRunner.cancel(run)            # from any process
      TLCRunner.await(run)             # owner only

  `run/2` is `start/2` followed by `await/1`.
  """

  alias Outlaw.Error

  @type result :: %{exit_status: non_neg_integer(), output: String.t()}

  defmodule Run do
    @moduledoc "A started TLC run: the runner process, the run's ref and its owner."
    @enforce_keys [:pid, :ref, :owner]
    defstruct [:pid, :ref, :owner]
    @type t :: %__MODULE__{pid: pid(), ref: reference(), owner: pid()}
  end

  @doc """
  Runs TLC to completion (or timeout / state limit) and returns its result.

  Options: `:java`, `:jar`, `:timeout` (ms or `:infinity`), `:max_states`
  (all required), `:cd`, `:tmp_dir`.

  Returns `{:ok, %{exit_status: status, output: output}}` when TLC exits, or
  `{:error, %Outlaw.Error{}}` with kind:

    * `:tlc_timeout` — `:timeout` ms passed; TLC was killed.
    * `:too_many_states` — TLC reported more than `:max_states` distinct
      states; TLC was killed.
    * `:tlc_crashed` — the runner process died without a result (e.g. the
      port could not be opened).

  (`run/2` awaits with `:infinity`, so it never returns `:await_timeout`.)
  """
  @spec run([String.t()], keyword()) :: {:ok, result()} | {:error, Error.t()}
  def run(tlc_args, opts) do
    {:ok, run} = start(tlc_args, opts)
    await(run)
  end

  @doc """
  Starts TLC in a new, unlinked runner process owned by the caller. Same
  options as `run/2`.
  """
  @spec start([String.t()], keyword()) :: {:ok, Run.t()}
  def start(tlc_args, opts) do
    config = %{
      java: Keyword.fetch!(opts, :java),
      jar: Keyword.fetch!(opts, :jar),
      timeout: Keyword.fetch!(opts, :timeout),
      max_states: Keyword.fetch!(opts, :max_states),
      cd: Keyword.get(opts, :cd, File.cwd!()),
      tmp_dir_args: tmp_dir_args(opts),
      args: tlc_args
    }

    owner = self()

    # The monitor ref doubles as the run's ref (reply/deadline/cancel tag); the
    # runner learns it from its first message.
    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          {:ref, ref} -> init_runner(owner, ref, config)
        end
      end)

    send(pid, {:ref, ref})
    {:ok, %Run{pid: pid, ref: ref, owner: owner}}
  end

  @doc """
  Waits for the run's result. Only the owner may await (others get an
  `ArgumentError`).

  Returns what `run/2` returns (`{:ok, result}`, or an error of kind
  `:tlc_timeout`, `:too_many_states` or `:tlc_crashed` — the last when the
  runner process dies without replying), plus:

    * `:tlc_cancelled` — `cancel/1` stopped the run; TLC was killed.
    * `:await_timeout` — `timeout` ms passed with no result yet. The run keeps
      going and the result is still delivered, so `await/2` may be called
      again.
  """
  @spec await(Run.t(), timeout()) :: {:ok, result()} | {:error, Error.t()}
  def await(%Run{pid: pid, ref: ref, owner: owner}, timeout \\ :infinity) do
    if owner != self() do
      raise ArgumentError, "only the owner (#{inspect(owner)}) may await a TLC run"
    end

    receive do
      {^ref, :result, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error,
         Error.new(:tlc_crashed, "The TLC runner process exited without a result.", %{
           reason: inspect(reason)
         })}
    after
      timeout ->
        {:error, Error.new(:await_timeout, "No TLC result within #{timeout}ms.", %{})}
    end
  end

  @doc """
  Stops the run: the runner kills TLC and the owner's `await/2` returns
  `{:error, %Outlaw.Error{kind: :tlc_cancelled}}`. Any process may cancel;
  cancelling a finished run is a no-op.
  """
  @spec cancel(Run.t()) :: :ok
  def cancel(%Run{pid: pid, ref: ref}) do
    send(pid, {:cancel, ref})
    :ok
  end

  # Test hook for the spec's Timeout action: makes the deadline pass now.
  @doc false
  def __expire__(%Run{pid: pid, ref: ref}) do
    send(pid, {:deadline, ref})
    :ok
  end

  # -- runner process ---------------------------------------------------------

  defp init_runner(owner, ref, config) do
    # Monitor before opening the port: an owner that is already dead yields an
    # immediate :DOWN, so there is no window with a JVM and no watchdog.
    owner_mon = Process.monitor(owner)

    port =
      Port.open({:spawn_executable, config.java}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:line, 65_536},
        {:cd, config.cd},
        {:args,
         config.tmp_dir_args ++
           ["-XX:+UseParallelGC", "-cp", config.jar, "tlc2.TLC"] ++ config.args}
      ])

    if config.timeout != :infinity do
      Process.send_after(self(), {:deadline, ref}, config.timeout)
    end

    result =
      loop(port, %{
        ref: ref,
        owner_mon: owner_mon,
        lines: [],
        partial: "",
        timeout: config.timeout,
        max_states: config.max_states
      })

    case result do
      :owner_down -> :ok
      result -> send(owner, {ref, :result, result})
    end
  end

  defp loop(port, %{ref: ref, owner_mon: owner_mon} = st) do
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

      {:deadline, ^ref} ->
        kill(port)

        {:error,
         Error.new(:tlc_timeout, "TLC did not finish within #{st.timeout}ms and was stopped.", %{
           output_tail: st.lines |> Enum.take(20) |> Enum.reverse() |> Enum.join("\n")
         })}

      {:cancel, ^ref} ->
        kill(port)
        {:error, Error.new(:tlc_cancelled, "The TLC run was cancelled.", %{})}

      # Watchdog: the owner is gone, nobody will read a result; don't orphan TLC.
      {:DOWN, ^owner_mon, :process, _, _} ->
        kill(port)
        :owner_down
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
