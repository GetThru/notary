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
  end
end
