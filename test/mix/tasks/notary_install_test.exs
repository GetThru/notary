defmodule Mix.Tasks.NotaryInstallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # Needs the real, checksum-matching jar installed (no download happens), so
  # it is excluded with the other :tlc tests until `mix notary.install` ran.
  @moduletag :tlc
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      Enum.each([:tla2tools_path, :java], &Application.delete_env(:notary, &1))
    end)

    %{dir: dir}
  end

  # Runs the task, capturing stdout/stderr and the exit code (the task is
  # expected to exit({:shutdown, N}) rather than let Mix.raise/2 crash the
  # caller, since a raised Mix.Error would itself look like a non-zero exit
  # when run from the `mix` CLI but behaves differently when run as a plain
  # function call in a test/consumer context).
  defp run_task(args) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            code =
              try do
                Mix.Task.rerun("notary.install", args)
                0
              catch
                :exit, {:shutdown, code} -> code
              end

            send(parent, {:exit_code, code})
          end)

        send(parent, {:stdout, stdout})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, stdout}
    {stdout <> stderr, code}
  end

  test "exits non-zero when Java is missing, after still installing the jar", %{dir: dir} do
    # Pre-seed a jar that already matches the pinned checksum (the real,
    # already-installed tla2tools.jar from this project's own `_build`), so
    # Tools.install/0's checksum short-circuit kicks in and no network
    # download is attempted.
    real_jar = Notary.Config.jar_path()

    unless File.exists?(real_jar) do
      flunk("""
      This test needs the real tla2tools.jar already installed at #{real_jar} \
      (run `mix notary.install` first) so it can verify the exit-code fix without \
      hitting the network for a matching checksum.
      """)
    end

    dest = Path.join(dir, "tla2tools.jar")
    File.cp!(real_jar, dest)

    Application.put_env(:notary, :tla2tools_path, dest)
    Application.put_env(:notary, :java, "definitely-not-java-xyz")

    {output, code} = run_task([])

    assert code != 0
    assert output =~ "ready at"
    assert output =~ "Java was not found"
    assert File.exists?(dest)
  end
end
