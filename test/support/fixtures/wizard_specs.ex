defmodule Notary.Fixtures.WizardSpec do
  @moduledoc false
  use Notary.Conformance, spec: "test/fixtures/specs/Wizard.tla"
  import Notary.Conformance.LiveView

  @endpoint Notary.Fixtures.Web.Endpoint

  @impl true
  def init, do: mount_variant("correct")

  def mount_variant(variant),
    do: mount(Notary.Fixtures.WizardLive, endpoint: @endpoint, session: %{"variant" => variant})

  @impl true
  def actions,
    do: Map.new(~w(EnterAddress Continue Back Pay StartOver), &{&1, StreamData.constant(%{})})

  @impl true
  def action("EnterAddress", _, ctx), do: submit(ctx, "#address-form", %{address: "1 Main St"})
  def action("Continue", _, ctx), do: click(ctx, "#continue")
  def action("Back", _, ctx), do: click(ctx, "#back")
  def action("Pay", _, ctx), do: click(ctx, "#pay")
  def action("StartOver", _, ctx), do: click(ctx, "#start-over")

  @impl true
  def project(ctx) do
    %{
      "step" => ctx |> text("#step-title") |> String.downcase(),
      "address" => has?(ctx, "#address-summary")
    }
  end

  @impl true
  def teardown(ctx), do: unmount(ctx)
end

defmodule Notary.Fixtures.WizardEarlyPaySpec do
  @moduledoc false
  # Bug: Pay is offered (and works) before the payment step.
  use Notary.Conformance, spec: "test/fixtures/specs/Wizard.tla", discover: false
  alias Notary.Fixtures.WizardSpec

  def init, do: WizardSpec.mount_variant("early_pay")
  defdelegate actions(), to: WizardSpec
  defdelegate action(name, params, ctx), to: WizardSpec
  defdelegate project(ctx), to: WizardSpec
  defdelegate teardown(ctx), to: WizardSpec
end

defmodule Notary.Fixtures.WizardNoPaySpec do
  @moduledoc false
  # Bug: Pay is never offered.
  use Notary.Conformance, spec: "test/fixtures/specs/Wizard.tla", discover: false
  alias Notary.Fixtures.WizardSpec

  def init, do: WizardSpec.mount_variant("no_pay")
  defdelegate actions(), to: WizardSpec
  defdelegate action(name, params, ctx), to: WizardSpec
  defdelegate project(ctx), to: WizardSpec
  defdelegate teardown(ctx), to: WizardSpec
end

defmodule Notary.Fixtures.WizardRedirectSpec do
  @moduledoc false
  # Correct, routed: Pay navigates to /wizard/done, StartOver navigates back.
  use Notary.Conformance, spec: "test/fixtures/specs/Wizard.tla", discover: false
  import Notary.Conformance.LiveView
  alias Notary.Fixtures.WizardSpec

  def init, do: mount("/wizard", endpoint: Notary.Fixtures.Web.Endpoint)
  defdelegate actions(), to: WizardSpec
  defdelegate action(name, params, ctx), to: WizardSpec
  defdelegate project(ctx), to: WizardSpec
  defdelegate teardown(ctx), to: WizardSpec
end
