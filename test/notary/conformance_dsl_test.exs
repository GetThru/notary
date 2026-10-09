defmodule Notary.DSL.GenTestProbe do
  @moduledoc "A DSL spec module defined in the generator-derivation test file."
  use Notary.DSL, name: "GenTestProbe"

  description("Generator-derivation probe.")

  variable(amount: 0..99)
  variable(mode: ["fast", "slow"])

  initial(amount: 0, mode: "fast")

  action Deposit, param: 1..2 do
    guard(amount + param <= 99)
    assign(amount: amount + param)
  end

  action Toggle do
    assign(mode: if(mode == "fast", do: "slow", else: "fast"))
  end
end

defmodule Notary.Conformance.DSLTest do
  use ExUnit.Case, async: true

  defmodule GenMapping do
    use Notary.Conformance.DSL, from: Notary.DSL.GenTestProbe

    def init, do: {:ok, nil}
    def action(_name, _params, ctx), do: {:ok, ctx}
    def project(_ctx), do: %{"amount" => 0, "mode" => "fast"}
  end

  test "actions/0 is derived from the DSL domains" do
    actions = GenMapping.actions()
    assert Map.keys(actions) |> Enum.sort() == ["Deposit", "Toggle"]

    assert %StreamData{} = actions["Toggle"]

    params = GenMapping.actions()["Deposit"] |> Enum.take(20)
    assert params |> Enum.map(& &1.param) |> Enum.uniq() |> Enum.sort() == [1, 2]
  end

  test "__gen__/1 override wins over the domain-derived generator" do
    defmodule OverriddenMapping do
      use Notary.Conformance.DSL, from: Notary.DSL.GenTestProbe

      def init, do: {:ok, nil}
      def action(_name, _params, ctx), do: {:ok, ctx}
      def project(_ctx), do: %{"amount" => 0, "mode" => "fast"}

      def __gen__("Deposit"), do: StreamData.constant(%{param: 2})
    end

    values = OverriddenMapping.actions()["Deposit"] |> Enum.take(5)
    assert Enum.all?(values, &(&1 == %{param: 2}))
  end

  test "internal actions are excluded from the derived actions" do
    defmodule InternalMapping do
      use Notary.Conformance.DSL, from: Notary.DSL.GenTestProbe, internal: ["Toggle"]

      def init, do: {:ok, nil}
      def action(_name, _params, ctx), do: {:ok, ctx}
      def project(_ctx), do: %{"amount" => 0, "mode" => "fast"}
    end

    assert Map.keys(InternalMapping.actions()) == ["Deposit"]
  end
end
