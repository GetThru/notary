defmodule Outlaw.CLITest do
  use ExUnit.Case, async: true

  alias Outlaw.CLI

  describe "colors?/3" do
    test "on: ANSI enabled, a real TTY (columns known), not --json" do
      assert CLI.colors?(true, {:ok, 80}, false) == true
    end

    test "off: ANSI disabled" do
      assert CLI.colors?(false, {:ok, 80}, false) == false
    end

    test "off: not a real terminal (:io.columns/1 reports :enotsup)" do
      assert CLI.colors?(true, {:error, :enotsup}, false) == false
    end

    test "off: --json, even if ANSI is enabled and columns are known" do
      assert CLI.colors?(true, {:ok, 80}, true) == false
    end

    test "on: json? is nil (the --json flag was never passed, not just false)" do
      assert CLI.colors?(true, {:ok, 80}, nil) == true
    end
  end

  describe "conformance_opts/1" do
    test "passes through valid opts" do
      assert CLI.conformance_opts(seed: 1, max_runs: 10, max_steps: 5, force: true) ==
               [seed: 1, max_runs: 10, max_steps: 5, force: true]
    end

    test "drops unrelated opts" do
      assert CLI.conformance_opts(max_runs: 3, json: true, force: false, other: :x) ==
               [max_runs: 3, force: false]
    end

    test "raises on --max-runs < 1" do
      assert_raise Mix.Error, ~r/max_runs must be an integer >= 1, got: 0/, fn ->
        CLI.conformance_opts(max_runs: 0)
      end

      assert_raise Mix.Error, ~r/got: -5/, fn ->
        CLI.conformance_opts(max_runs: -5)
      end
    end

    test "raises on --max-steps < 1" do
      assert_raise Mix.Error, ~r/max_steps must be an integer >= 1/, fn ->
        CLI.conformance_opts(max_steps: 0)
      end
    end

    test "accepts absence" do
      assert CLI.conformance_opts([]) == []
    end
  end
end
