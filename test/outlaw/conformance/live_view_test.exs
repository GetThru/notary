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
          {ExUnit.OnExitHandler.get_supervisor(self()), html}
        end)

      assert {:error, html} = Task.await(task)
      assert html =~ ~s(id="flip")
    end

    test "a path that isn't routed is an Outlaw.Error naming the path and status" do
      task =
        Task.async(fn ->
          result =
            try do
              mount("/no-such-page", endpoint: Endpoint)
            rescue
              e in Outlaw.Error -> e
            end

          {result, ExUnit.OnExitHandler.get_supervisor(self())}
        end)

      assert {%Outlaw.Error{kind: :invalid_mapping, message: message}, :error} =
               Task.await(task)

      assert message =~ "/no-such-page"
      assert message =~ "404"
    end

    test "a page answering with a status other than 200 or a redirect is an Outlaw.Error" do
      assert_raise Outlaw.Error, ~r{"/teapot".*418}, fn ->
        mount("/teapot", endpoint: Endpoint)
      end
    end
  end

  describe "unmount/1" do
    test "a second unmount is a no-op :ok and leaves trap_exit as it was" do
      task =
        Task.async(fn ->
          {:ok, ctx} = mount(ToggleLive, endpoint: Endpoint)
          :ok = unmount(ctx)
          {unmount(ctx), Process.info(self(), :trap_exit)}
        end)

      assert {:ok, {:trap_exit, false}} = Task.await(task)
    end

    test "re-mounting in the same process, then unmounting, cleans up the registration" do
      task =
        Task.async(fn ->
          {:ok, _first} = mount(ToggleLive, endpoint: Endpoint)
          {:ok, second} = mount(ToggleLive, endpoint: Endpoint)
          :ok = unmount(second)
          {ExUnit.OnExitHandler.get_supervisor(self()), Process.info(self(), :trap_exit)}
        end)

      assert {:error, {:trap_exit, false}} = Task.await(task)
    end

    test "unmount in an ExUnit test process (not registered by Outlaw) does nothing" do
      {:ok, ctx} = mount(ToggleLive, endpoint: Endpoint)
      assert :ok = unmount(ctx)
      assert {:ok, sup} = ExUnit.OnExitHandler.get_supervisor(self())
      assert Process.alive?(sup)
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
      assert text(ctx, "#page") == "Done"
    end

    test "redirect to a page that isn't a LiveView gives view: nil and projects its html" do
      {:ok, ctx} = mount("/toggle", endpoint: Endpoint)
      assert {:ok, ctx} = click(ctx, "#leave")
      assert ctx.view == nil
      assert text(ctx, "#page") == "Plain"
      assert {:rejected, {:not_available, "#flip"}, _} = click(ctx, "#flip")
    end

    test "a redirect target settles its async mount work before projection" do
      {:ok, ctx} = mount("/toggle", endpoint: Endpoint)
      assert {:ok, ctx} = click(ctx, "#go-async")
      assert text(ctx, "#status") == "loaded"
    end

    test "mounting an async LiveView directly also settles before projection" do
      assert {:ok, ctx} = mount("/async", endpoint: Endpoint)
      assert text(ctx, "#status") == "loaded"
    end
  end

  describe "click/2" do
    test "an available element is clicked and the result is {:ok, ctx}" do
      assert {:ok, ctx} = click(toggle(), "#flip")
      assert text(ctx, "#on-state") == "On"
    end

    test "a disabled element is not available and sends no event" do
      ctx = toggle()
      assert {:rejected, {:not_available, "#off"}, ^ctx} = click(ctx, "#off")
      assert text(ctx, "#on-state") == "Off"
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
      assert text(ctx, "#name") == "ada"
    end

    test "a form whose only submit button is disabled is not available" do
      {:ok, ctx} = click(toggle(), "#lock")

      assert {:rejected, {:not_available, "#name-form"}, _} =
               submit(ctx, "#name-form", %{name: "x"})
    end

    test "a form without a submit button is available" do
      assert {:ok, ctx} = submit(toggle(), "#bare-form", %{name: "bo"})
      assert text(ctx, "#name") == "bo"
    end

    test "change sends a change event even when submit is disabled" do
      {:ok, ctx} = click(toggle(), "#lock")
      assert {:ok, ctx} = change(ctx, "#name-form", %{name: "cy"})
      assert text(ctx, "#name") == "typing:cy"
    end

    test "a missing form is not available" do
      assert {:rejected, {:not_available, "#nope"}, _} = submit(toggle(), "#nope", %{})
    end
  end

  describe "async settling" do
    test "start_async results land before the helper returns" do
      assert {:ok, ctx} = click(toggle(), "#slow")
      assert text(ctx, "#slow-state") == "finished"
    end
  end

  describe "text/2" do
    test "trims and collapses internal whitespace runs to one space" do
      assert text(toggle(), "#messy-text") == "Hello World"
    end

    test "0 matches throws :invalid_projection naming the helper, selector, and count" do
      assert {:outlaw_fail, :invalid_projection, %{message: message}} =
               catch_throw(text(toggle(), "#nope"))

      assert message == ~s{text(ctx, "#nope") matched 0 elements; it needs exactly one}
    end

    test "2+ matches throws :invalid_projection naming the helper, selector, and count" do
      assert {:outlaw_fail, :invalid_projection, %{message: message}} =
               catch_throw(text(toggle(), ".dup"))

      assert message == ~s{text(ctx, ".dup") matched 2 elements; it needs exactly one}
    end

    test "does not include a variable key (not meaningful here)" do
      assert {:outlaw_fail, :invalid_projection, details} = catch_throw(text(toggle(), "#nope"))
      refute Map.has_key?(details, :variable)
    end

    test "excludes <script> and <style> content, but still includes hidden elements" do
      assert text(toggle(), "#with-script") == "Hello"
      assert text(toggle(), "#hidden-para") == "Hidden but present"
    end

    test "collapses non-breaking spaces like ordinary whitespace" do
      assert text(toggle(), "#nbsp-text") == "Hello World"
    end
  end

  describe "texts/2" do
    test "returns normalised text for every match, in document order" do
      assert texts(toggle(), "#items li") == ["One", "Two", "Three"]
    end

    test "no matches is an empty list" do
      assert texts(toggle(), "#empty-list li") == []
    end
  end

  describe "has?/2" do
    test "true when at least one element matches" do
      assert has?(toggle(), "#flip")
    end

    test "false when no element matches" do
      refute has?(toggle(), "#nope")
    end
  end

  describe "count/2" do
    test "counts matching elements" do
      assert count(toggle(), "#items li") == 3
    end

    test "0 for no matches" do
      assert count(toggle(), "#nope") == 0
    end
  end

  describe "attr/3" do
    test "the attribute's value when present" do
      assert attr(toggle(), "#flip", "id") == "flip"
    end

    test "nil when the attribute is absent" do
      {:ok, ctx} = click(toggle(), "#flip")
      assert attr(ctx, "#off", "disabled") == nil
    end

    test "boolean attributes present with no value give an empty string" do
      assert attr(toggle(), "#off", "disabled") == ""
    end

    test "0 or 2+ matches throws :invalid_projection naming the helper, selector, attribute and count" do
      assert {:outlaw_fail, :invalid_projection, %{message: message}} =
               catch_throw(attr(toggle(), ".dup", "class"))

      assert message == ~s{attr(ctx, ".dup", "class") matched 2 elements; it needs exactly one}
    end
  end

  describe "value/2" do
    test "an <input>'s value attribute" do
      assert value(toggle(), "#bare-form input") == ""
      {:ok, ctx} = submit(toggle(), "#bare-form", %{name: "bo"})
      assert value(ctx, "#bare-form input") == "bo"
    end

    test "an <input> with no value attribute gives an empty string" do
      assert value(toggle(), "#unset") == ""
    end

    test "a <textarea>'s raw text content, not whitespace-collapsed" do
      assert value(toggle(), "#bio") == "  padded  text  "
    end

    test "a <select>'s selected option" do
      assert value(toggle(), "#color") == "green"
    end

    test "a <select> with no selected option gives the first option's value" do
      assert value(toggle(), "#unselected") == "a"
    end

    test "a <select> with no options gives an empty string" do
      assert value(toggle(), "#empty-select") == ""
    end

    test "a <select>'s selected option falls back to its text when it has no value attribute" do
      assert value(toggle(), "#option-text-selected") == "Beta"
    end

    test "a <select> with no selected option falls back to the first option's text when it has no value attribute" do
      assert value(toggle(), "#option-text-unselected") == "Alpha"
    end

    test "0 or 2+ matches throws :invalid_projection naming the helper, selector, and count" do
      assert {:outlaw_fail, :invalid_projection, %{message: message}} =
               catch_throw(value(toggle(), ".dup"))

      assert message == ~s{value(ctx, ".dup") matched 2 elements; it needs exactly one}
    end
  end

  describe "DOM helpers on a static page (view: nil)" do
    setup do
      {:ok, ctx} = mount("/plain", endpoint: Endpoint)
      %{ctx: ctx}
    end

    test "text/2", %{ctx: ctx} do
      assert text(ctx, "#page") == "Plain"
    end

    test "has?/2", %{ctx: ctx} do
      assert has?(ctx, "#page")
      refute has?(ctx, "#nope")
    end

    test "count/2", %{ctx: ctx} do
      assert count(ctx, "#page") == 1
    end

    test "attr/3", %{ctx: ctx} do
      assert attr(ctx, "#page", "id") == "page"
    end
  end

  describe "assigns/1" do
    test "returns the LiveView socket's assigns map" do
      {:ok, ctx} = click(toggle(), "#flip")
      result = assigns(ctx)
      assert result.on == true
      assert result.name == ""
    end

    test "an Outlaw.Error when the current page isn't a LiveView" do
      {:ok, ctx} = mount("/plain", endpoint: Endpoint)

      assert_raise Outlaw.Error, ~r/assigns\/1 needs a LiveView/, fn ->
        assigns(ctx)
      end
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
