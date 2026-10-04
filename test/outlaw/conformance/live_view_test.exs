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

  defp toggle do
    {:ok, ctx} = mount(ToggleLive, endpoint: Endpoint)
    ctx
  end

  describe "redirects" do
    test "push_navigate to another LiveView replaces the view" do
      {:ok, ctx} = mount("/toggle", endpoint: Endpoint)
      assert {:ok, ctx} = click(ctx, "#go")
      assert ctx.view != nil
      assert project_dom(ctx) == %{"page" => "done"}
    end

    test "redirect to a page that isn't a LiveView gives view: nil and projects its html" do
      {:ok, ctx} = mount("/toggle", endpoint: Endpoint)
      assert {:ok, ctx} = click(ctx, "#leave")
      assert ctx.view == nil
      assert project_dom(ctx) == %{"page" => "plain"}
      assert {:rejected, {:not_available, "#flip"}, _} = click(ctx, "#flip")
    end

    test "a redirect target settles its async mount work before projection" do
      {:ok, ctx} = mount("/toggle", endpoint: Endpoint)
      assert {:ok, ctx} = click(ctx, "#go-async")
      assert project_dom(ctx) == %{"status" => "loaded"}
    end

    test "mounting an async LiveView directly also settles before projection" do
      assert {:ok, ctx} = mount("/async", endpoint: Endpoint)
      assert project_dom(ctx) == %{"status" => "loaded"}
    end
  end

  describe "click/2" do
    test "an available element is clicked and the result is {:ok, ctx}" do
      assert {:ok, ctx} = click(toggle(), "#flip")
      assert project_dom(ctx)["on"] == true
    end

    test "a disabled element is not available and sends no event" do
      ctx = toggle()
      assert {:rejected, {:not_available, "#off"}, ^ctx} = click(ctx, "#off")
      assert project_dom(ctx)["on"] == false
    end

    test "an element removed by :if is not available" do
      assert {:rejected, {:not_available, "#only-when-on"}, _} = click(toggle(), "#only-when-on")
      {:ok, ctx} = click(toggle(), "#flip")
      assert {:ok, _} = click(ctx, "#only-when-on")
    end

    test "a selector matching several elements is a mapping bug, not a verdict" do
      assert_raise Outlaw.Error, ~r/\.dup.*2 elements/, fn -> click(toggle(), ".dup") end
    end
  end

  describe "submit/3 and change/3" do
    test "submit sends the values" do
      assert {:ok, ctx} = submit(toggle(), "#name-form", %{name: "ada"})
      assert project_dom(ctx)["name"] == "ada"
    end

    test "a form whose only submit button is disabled is not available" do
      {:ok, ctx} = click(toggle(), "#lock")

      assert {:rejected, {:not_available, "#name-form"}, _} =
               submit(ctx, "#name-form", %{name: "x"})
    end

    test "a form without a submit button is available" do
      assert {:ok, ctx} = submit(toggle(), "#bare-form", %{name: "bo"})
      assert project_dom(ctx)["name"] == "bo"
    end

    test "change sends a change event even when submit is disabled" do
      {:ok, ctx} = click(toggle(), "#lock")
      assert {:ok, ctx} = change(ctx, "#name-form", %{name: "cy"})
      assert project_dom(ctx)["name"] == "typing:cy"
    end

    test "a missing form is not available" do
      assert {:rejected, {:not_available, "#nope"}, _} = submit(toggle(), "#nope", %{})
    end
  end

  describe "async settling" do
    test "start_async results land before the helper returns" do
      assert {:ok, ctx} = click(toggle(), "#slow")
      assert project_dom(ctx)["slow"] == "finished"
    end
  end

  describe "project_dom/1 and project_assigns/2" do
    test "projects every marker" do
      assert project_dom(toggle()) == %{"on" => false, "name" => "", "slow" => "idle"}
    end

    test "a bad marker throws :invalid_projection for the runner" do
      ctx = %{toggle() | view: nil, html: ~s(<span data-outlaw-var="x"></span>)}

      assert {:outlaw_fail, :invalid_projection, %{variable: "x", message: _}} =
               catch_throw(project_dom(ctx))
    end

    test "project_assigns reads the given assigns as string keys" do
      {:ok, ctx} = click(toggle(), "#flip")
      assert project_assigns(ctx, [:on, :name]) == %{"on" => true, "name" => ""}
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
