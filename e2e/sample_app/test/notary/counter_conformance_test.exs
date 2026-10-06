defmodule SampleApp.Specs.CounterTest do
  use ExUnit.Case, async: false

  test "Counter conforms to its TLA+ spec" do
    Notary.Conformance.assert_conforms(SampleApp.Specs.Counter)
  end
end
