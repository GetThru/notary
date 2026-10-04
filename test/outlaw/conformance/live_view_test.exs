defmodule Outlaw.Conformance.LiveViewTest do
  use ExUnit.Case, async: true

  import Outlaw.Conformance.LiveView
  alias Outlaw.Conformance.LiveView.Ctx
  alias Outlaw.Fixtures.Web.{Endpoint, ToggleLive}

  describe "mount/2" do
    test "mounts a module in isolation" do
      assert {:ok, %Ctx{view: view, endpoint: Endpoint}} = mount(ToggleLive, endpoint: Endpoint)
      assert Phoenix.LiveViewTest.render(view) =~ ~s(id="flip")
    end

    test "mounts a routed path" do
      assert {:ok, %Ctx{view: view}} = mount("/toggle", endpoint: Endpoint)
      assert Phoenix.LiveViewTest.render(view) =~ ~s(id="flip")
    end

    test "mounts a path that isn't a LiveView as static html" do
      assert {:ok, %Ctx{view: nil, html: html}} = mount("/plain", endpoint: Endpoint)
      assert html =~ "Plain"
    end

    test "works from a process that is not the ExUnit test process (the runner's run process)" do
      task =
        Task.async(fn ->
          {:ok, ctx} = mount(ToggleLive, endpoint: Endpoint)
          html = Phoenix.LiveViewTest.render(ctx.view)
          :ok = unmount(ctx)
          {ctx.registered?, html}
        end)

      assert {true, html} = Task.await(task)
      assert html =~ ~s(id="flip")
    end
  end
end

defmodule Outlaw.Conformance.LiveViewConfigTest do
  # Mutates global application env, so not async.
  use ExUnit.Case, async: false

  import Outlaw.Conformance.LiveView
  alias Outlaw.Conformance.LiveView.Ctx
  alias Outlaw.Fixtures.Web.{Endpoint, ToggleLive}

  test "the endpoint falls back to config :outlaw, endpoint:" do
    Application.put_env(:outlaw, :endpoint, Endpoint)
    on_exit(fn -> Application.delete_env(:outlaw, :endpoint) end)
    assert {:ok, %Ctx{endpoint: Endpoint}} = mount(ToggleLive)
  end

  test "no endpoint anywhere is an Outlaw.Error" do
    assert_raise Outlaw.Error, ~r/endpoint/, fn -> mount(ToggleLive) end
  end
end
