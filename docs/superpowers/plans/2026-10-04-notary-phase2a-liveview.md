# Notary Phase 2a: LiveView Conformance (single view) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a mapping module drive and observe a single Phoenix LiveView with `Notary.Conformance.LiveView` helpers, and add the runner rule that a UI must offer what the spec allows (`:action_not_offered`).

**Architecture:**
- **Helpers.** The helpers sit on the existing mapping contract (design spec §4) and return the runner's `{:ok, ctx} | {:rejected, reason, ctx}`. They wrap `Phoenix.LiveViewTest`, and `LazyHTML` does the DOM queries.
- **Projection.** It reads plain `data-notary-var` markup, through a pure decoder `Notary.Conformance.LiveView.Dom`.
- **Runner.** It gains one rule: a `{:not_available, _}` rejection fails with `:action_not_offered` when every candidate state enables the action.

**Tech Stack:** Elixir 1.19, `phoenix_live_view ~> 1.2` (optional), `lazy_html ~> 0.1` (optional), Elixir's built-in `JSON`, StreamData, TLC (only to generate the `Wizard.dot` fixture once).

**Spec:** `docs/superpowers/specs/2026-09-30-notary-design.md`. Read §4, §5 and §8 (8.1 to 8.7), plus the Phase 2a parts of §11 and §12.

## Global Constraints

- **Dependencies.** Add `{:phoenix_live_view, "~> 1.2", optional: true}` and `{:lazy_html, "~> 0.1", optional: true}`. Everything under `Notary.Conformance.LiveView*` must compile to nothing when either is missing (`if Code.ensure_loaded?(Phoenix.LiveViewTest) and Code.ensure_loaded?(LazyHTML) do ... end`).
- **App code never calls Notary.** Markup uses only `data-notary-var` plus exactly one of `data-notary-json` (decoded with the built-in `JSON`) or `data-notary-value` (TLC syntax, `Notary.Value.parse/1`).
- **Rejection reason.** For an unavailable element it is exactly `{:not_available, selector}`. The runner also accepts a bare `:not_available`.
- **Failure kind name.** `:action_not_offered`, with the explanation: "The spec allows this action here, but the UI did not offer it (the element was missing or disabled)."
- **The rule.** "Every state in `B := closure(C)` has a successor labelled `name`" ⇒ `:action_not_offered`. It is checked before the projection comparison of a rejected step.
- **Specs are human territory.** Never edit `specs/`. `test/fixtures/specs/Wizard.tla` is written *with* the human in Task 6, and their edits win.
- **Commits.** End every commit message with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **Gates.** `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test` must all pass at the end of every task.

## Review Focus

1. **Called from the runner's spawned run process, or from `mix notary.verify`**, where no ExUnit test process exists. `mount/2` must still work, because LiveViewTest requires an ExUnit test supervisor. Task 1 tests it from a spawned process. The `mix notary.verify` path (ExUnit app not started) is covered by `ensure_all_started(:ex_unit)` and is checked manually in Task 7.
2. **Elements that exist but are hidden by `:if` or appear twice.** `:if` removes the element, which counts as unavailable. A selector matching more than one element raises an `Notary.Error` and is never treated as a UI verdict (Task 3 test).
- 3. **A form whose only submit button is disabled**, or a form with no submit button at all. The first is unavailable; the second is available (Task 3 tests).
- 4. **A JSON `null`, a float, or a variable rendered twice with different values.** Each is `:invalid_projection` with a message naming the variable. The same value rendered twice is fine (Task 2 tests).
- 5. **Hidden variables leaving candidates that disagree on enabledness.** A `:not_available` rejection must pass (not fail) when only *some* candidates enable the action (Task 5 test with a synthetic graph).

---

## File Structure

| File | Responsibility |
|---|---|
| `mix.exs` | Optional deps; `elixirc_paths(:test)` stays `["lib", "test/support"]`. |
| `lib/notary/config.ex` | New default `endpoint: nil`. |
| `lib/notary/conformance/live_view.ex` | `Notary.Conformance.LiveView` with `mount/2`, `click/2`, `submit/3`, `change/3`, `project_dom/1`, `project_assigns/2`, `unmount/1`. |
| `lib/notary/conformance/live_view/ctx.ex` | `%Ctx{}` struct. |
| `lib/notary/conformance/live_view/dom.ex` | `Dom.decode/1`: HTML → `{:ok, %{var => value}} \| {:error, message}`. |
| `lib/notary/conformance/runner.ex` | The `:action_not_offered` rule. |
| `lib/notary/conformance/failure.ex` | New kind and explanation. |
| `lib/notary/diagnostic.ex` | Diagnostic and headline for `:action_not_offered`. |
| `test/support/web/endpoint.ex`, `router.ex`, `page_controller.ex` | Minimal Phoenix endpoint, router and plain page for tests; `Notary.Fixtures.Web.start!/0`. |
| `test/support/web/toggle_live.ex`, `done_live.ex` | LiveViews used by the helper tests. |
| `test/support/fixtures/wizard_live.ex` | `WizardLive` (variants by session) and `WizardDoneLive`. |
| `test/support/fixtures/wizard_specs.ex` | Wizard mapping modules (correct, early-pay, no-pay, redirect). |
| `test/support/fixtures/counter_specs.ex` | Adds `CounterNotOfferedSpec`. |
| `test/fixtures/specs/Wizard.tla`, `.cfg` | Written with the human (Task 6). |
| `test/fixtures/graphs/Wizard.dot` | Generated by TLC via `regen_graphs.exs`. |
| `test/fixtures/measure_wizard.exs` | Catch-rate measurement script. |
| `test/test_helper.exs` | Starts the test endpoint. |
| `test/notary/conformance/live_view/dom_test.exs` | `Dom` tests. |
| `test/notary/conformance/live_view_test.exs` | Helper tests. |
| `test/notary/conformance/runner_test.exs`, `test/notary/diagnostic_test.exs` | `:action_not_offered` and wizard tests. |
| `guides/liveview.md`, `README.md`, `mix.exs` docs extras, `priv/templates/mapping.ex.eex` | Docs. |

---

### Task 1: Dependencies, test endpoint, `Ctx`, and `mount/2` from any process

**Files:**
- Modify: `mix.exs` (deps)
- Modify: `lib/notary/config.ex` (`@defaults`)
- Create: `lib/notary/conformance/live_view/ctx.ex`
- Create: `lib/notary/conformance/live_view.ex` (`mount/2`, `unmount/1` only in this task)
- Create: `test/support/web/endpoint.ex`, `test/support/web/router.ex`, `test/support/web/page_controller.ex`, `test/support/web/toggle_live.ex`, `test/support/web/done_live.ex`
- Modify: `test/test_helper.exs`
- Test: `test/notary/conformance/live_view_test.exs`

**Interfaces:**
- Produces:
  - `%Notary.Conformance.LiveView.Ctx{conn: Plug.Conn.t(), view: Phoenix.LiveViewTest.View.t() | nil, html: String.t(), endpoint: module(), registered?: boolean(), assigns: map()}`;
  - `Notary.Conformance.LiveView.mount(module() | String.t(), keyword()) :: {:ok, Ctx.t()}` (opts `:endpoint`, `:session`);
  - `unmount(Ctx.t()) :: :ok`;
  - `Notary.Config.get(:endpoint)`;
  - `Notary.Fixtures.Web.start!/0`;
  - test LiveViews `Notary.Fixtures.Web.ToggleLive` (routed at `/toggle`) and `Notary.Fixtures.Web.DoneLive` (`/done`);
  - a plain page at `/plain`.

- [ ] **Step 1: Add deps and fetch**

In `mix.exs` `deps/0`:

```elixir
  defp deps do
    [
      {:stream_data, "~> 1.1"},
      {:pentiment, "~> 0.2.1"},
      {:phoenix_live_view, "~> 1.2", optional: true},
      {:lazy_html, "~> 0.1", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
```

Run: `mix deps.get && mix compile --warnings-as-errors`
Expected: compiles. `phoenix`, `plug`, `phoenix_html` and others arrive as LiveView's deps.

- [ ] **Step 2: Add the `endpoint` config default**

In `lib/notary/config.ex` `@defaults`, add `endpoint: nil,` after `java: "java",`. In `test/notary/config_test.exs` "returns defaults", add `assert Config.get(:endpoint) == nil`.

- [ ] **Step 3: Write the test endpoint, router, plain page and test LiveViews**

`test/support/web/endpoint.ex`:

```elixir
defmodule Notary.Fixtures.Web.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :notary

  @session [store: :cookie, key: "_notary_test", signing_salt: "notary-test-salt"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  plug Plug.Session, @session
  plug Notary.Fixtures.Web.Router
end

defmodule Notary.Fixtures.Web do
  @moduledoc false

  # Starts the test endpoint once per VM (test_helper.exs, measurement scripts).
  def start! do
    Application.put_env(:phoenix, :json_library, JSON)

    Application.put_env(:notary, Notary.Fixtures.Web.Endpoint,
      secret_key_base: String.duplicate("notary", 11),
      live_view: [signing_salt: "notary-live-salt"],
      server: false
    )

    case Notary.Fixtures.Web.Endpoint.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
```

`test/support/web/router.ex`:

```elixir
defmodule Notary.Fixtures.Web.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :fetch_live_flash
  end

  scope "/" do
    pipe_through :browser

    live "/toggle", Notary.Fixtures.Web.ToggleLive
    live "/done", Notary.Fixtures.Web.DoneLive
    get "/plain", Notary.Fixtures.Web.PageController, :plain
  end
end
```

(Task 7 adds the wizard routes to this scope.)

`test/support/web/page_controller.ex`:

```elixir
defmodule Notary.Fixtures.Web.PageController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  def plain(conn, _params) do
    html(conn, ~s(<p><span hidden data-notary-var="page" data-notary-json='"plain"'></span>Plain</p>))
  end
end
```

`test/support/web/toggle_live.ex`. It covers every helper case in Tasks 1, 3 and 4:

```elixir
defmodule Notary.Fixtures.Web.ToggleLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, on: false, name: "", locked: false, slow: "idle")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <span hidden data-notary-var="on" data-notary-json={JSON.encode!(@on)}></span>
      <span hidden data-notary-var="name" data-notary-json={JSON.encode!(@name)}></span>
      <span hidden data-notary-var="slow" data-notary-json={JSON.encode!(@slow)}></span>
      <button id="flip" phx-click="flip">Flip</button>
      <button id="off" phx-click="off" disabled={not @on}>Off</button>
      <button :if={@on} id="only-when-on" phx-click="off">Off (conditional)</button>
      <button class="dup" phx-click="flip">A</button>
      <button class="dup" phx-click="flip">B</button>
      <button id="lock" phx-click="lock">Lock</button>
      <form id="name-form" phx-submit="save" phx-change="typing">
        <input name="name" value={@name} />
        <button type="submit" disabled={@locked}>Save</button>
      </form>
      <form id="bare-form" phx-submit="save">
        <input name="name" value={@name} />
      </form>
      <button id="slow" phx-click="slow">Slow</button>
      <button id="go" phx-click="go">Go</button>
      <button id="leave" phx-click="leave">Leave</button>
    </div>
    """
  end

  def handle_event("flip", _, socket), do: {:noreply, update(socket, :on, &(not &1))}
  def handle_event("off", _, socket), do: {:noreply, assign(socket, on: false)}
  def handle_event("lock", _, socket), do: {:noreply, assign(socket, locked: true)}
  def handle_event("save", %{"name" => name}, socket), do: {:noreply, assign(socket, name: name)}
  def handle_event("typing", %{"name" => name}, socket), do: {:noreply, assign(socket, name: "typing:" <> name)}
  def handle_event("go", _, socket), do: {:noreply, push_navigate(socket, to: "/done")}
  def handle_event("leave", _, socket), do: {:noreply, redirect(socket, to: "/plain")}

  def handle_event("slow", _, socket) do
    {:noreply,
     socket
     |> assign(slow: "running")
     |> start_async(:slow, fn -> Process.sleep(50) && "finished" end)}
  end

  def handle_async(:slow, {:ok, result}, socket), do: {:noreply, assign(socket, slow: result)}
end
```

`test/support/web/done_live.ex`:

```elixir
defmodule Notary.Fixtures.Web.DoneLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <div><span hidden data-notary-var="page" data-notary-json={JSON.encode!("done")}></span>Done</div>
    """
  end
end
```

In `test/test_helper.exs`, before `ExUnit.start(...)`, add:

```elixir
Notary.Fixtures.Web.start!()
```

- [ ] **Step 4: Write the failing tests for `mount/2`**

`test/notary/conformance/live_view_test.exs`:

```elixir
defmodule Notary.Conformance.LiveViewTest do
  use ExUnit.Case, async: true

  import Notary.Conformance.LiveView
  alias Notary.Conformance.LiveView.Ctx
  alias Notary.Fixtures.Web.{Endpoint, ToggleLive}

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

defmodule Notary.Conformance.LiveViewConfigTest do
  # Mutates global application env, so not async.
  use ExUnit.Case, async: false

  import Notary.Conformance.LiveView
  alias Notary.Conformance.LiveView.Ctx
  alias Notary.Fixtures.Web.{Endpoint, ToggleLive}

  test "the endpoint falls back to config :notary, endpoint:" do
    Application.put_env(:notary, :endpoint, Endpoint)
    on_exit(fn -> Application.delete_env(:notary, :endpoint) end)
    assert {:ok, %Ctx{endpoint: Endpoint}} = mount(ToggleLive)
  end

  test "no endpoint anywhere is an Notary.Error" do
    assert_raise Notary.Error, ~r/endpoint/, fn -> mount(ToggleLive) end
  end
end
```

Both modules live in the same file. Later tasks append `describe` blocks to `Notary.Conformance.LiveViewTest`, the first module, and their `defp` helpers go inside it.

- [ ] **Step 5: Run the tests to verify they fail**

Run: `mix test test/notary/conformance/live_view_test.exs`
Expected: FAIL, `module Notary.Conformance.LiveView is not available` / `mount/2 undefined`.

- [ ] **Step 6: Implement `Ctx`, `mount/2` and `unmount/1`**

`lib/notary/conformance/live_view/ctx.ex`:

```elixir
if Code.ensure_loaded?(Phoenix.LiveViewTest) and Code.ensure_loaded?(LazyHTML) do
  defmodule Notary.Conformance.LiveView.Ctx do
    @moduledoc """
    The context `Notary.Conformance.LiveView` helpers pass through a mapping's
    callbacks (design spec §8.2). `view` is the current LiveView, or `nil`
    after a redirect to a page that isn't a LiveView (then `html` is that
    page). `assigns` is free space for the mapping (a stub's pid, ...).
    """
    defstruct [:conn, :view, :endpoint, html: "", registered?: false, assigns: %{}]

    @type t :: %__MODULE__{
            conn: Plug.Conn.t(),
            view: Phoenix.LiveViewTest.View.t() | nil,
            html: String.t(),
            endpoint: module(),
            registered?: boolean(),
            assigns: map()
          }
  end
end
```

`lib/notary/conformance/live_view.ex` (this task's part):

```elixir
if Code.ensure_loaded?(Phoenix.LiveViewTest) and Code.ensure_loaded?(LazyHTML) do
  defmodule Notary.Conformance.LiveView do
    @moduledoc """
    Helpers for mapping modules that drive a Phoenix LiveView (design spec §8).

        defmodule MyAppWeb.Specs.Wizard do
          use Notary.Conformance, spec: "specs/Wizard.tla"
          import Notary.Conformance.LiveView

          def init, do: mount(MyAppWeb.WizardLive, endpoint: MyAppWeb.Endpoint)
          def actions, do: %{"Pay" => StreamData.constant(%{}), ...}
          def action("Pay", _, ctx), do: click(ctx, "#pay")
          def project(ctx), do: project_dom(ctx)
          def teardown(ctx), do: unmount(ctx)
        end

    Built on `Phoenix.LiveViewTest`, including some of its undocumented
    functions (`__live__/3`, `__isolated__/4`, `__follow_redirect__/4`), and
    ExUnit's internal test-supervisor registration: LiveViewTest only runs in
    an ExUnit test process, and conformance runs happen in their own process.
    """

    alias Notary.Conformance.LiveView.Ctx

    @doc """
    Mounts `target` and returns `{:ok, ctx}`. `target` is a LiveView module
    (mounted in isolation, no router needed) or a path (requires a router;
    redirects are followed; a page that isn't a LiveView gives `view: nil`).

    Options: `:endpoint` (default `config :notary, endpoint:`), `:session`
    (for a module target).
    """
    @spec mount(module() | String.t(), keyword()) :: {:ok, Ctx.t()}
    def mount(target, opts \\ []) do
      endpoint =
        opts[:endpoint] || Notary.Config.get(:endpoint) ||
          raise Notary.Error.new(
                  :invalid_mapping,
                  "Notary.Conformance.LiveView.mount/2 needs an endpoint: pass endpoint: MyAppWeb.Endpoint or set config :notary, endpoint: MyAppWeb.Endpoint"
                )

      registered? = ensure_test_supervisor()
      conn = Phoenix.ConnTest.build_conn()
      ctx = %Ctx{conn: conn, endpoint: endpoint, registered?: registered?}

      result =
        if is_binary(target) do
          visit(conn, endpoint, target)
        else
          conn
          |> Phoenix.LiveViewTest.__isolated__(endpoint, target, session: opts[:session] || %{})
          |> live_result(conn)
        end

      {:ok, put_result(ctx, result)}
    end

    @doc "Cleans up what `mount/2` registered. Call it from `teardown/1`."
    @spec unmount(Ctx.t()) :: :ok
    def unmount(%Ctx{registered?: true}) do
      _ = ExUnit.OnExitHandler.run(self(), 5_000)
      :ok
    end

    def unmount(%Ctx{}), do: :ok

    # LiveViewTest refuses to run outside an ExUnit test process
    # (`ExUnit.fetch_test_supervisor/0`). The runner's per-run process isn't
    # one, and `mix notary.verify` doesn't start ExUnit at all, so register
    # the calling process the way ExUnit's own runner does. Returns whether
    # we registered (so `unmount/1` knows to clean up).
    defp ensure_test_supervisor do
      {:ok, _} = Application.ensure_all_started(:ex_unit)

      case ExUnit.fetch_test_supervisor() do
        {:ok, _} ->
          false

        :error ->
          :ok = ExUnit.OnExitHandler.register(self())
          true
      end
    end

    @doc false
    # GETs `path`; a LiveView response is connected, anything else is static.
    def visit(conn, endpoint, path) do
      conn = Phoenix.ConnTest.dispatch(conn, endpoint, :get, path, nil)

      case conn do
        %Plug.Conn{status: 200, assigns: %{live_module: _}} ->
          live_result(Phoenix.LiveViewTest.__live__(conn, path, []), conn)

        %Plug.Conn{status: 200} ->
          {:static, conn, conn.resp_body}

        %Plug.Conn{status: status} when status in 300..399 ->
          [to | _] = Plug.Conn.get_resp_header(conn, "location")
          {:redirect, conn, %{to: to}}
      end
    end

    defp live_result({:ok, view, html}, conn), do: {:live, conn, view, html}
    defp live_result({:error, {_kind, %{to: _} = opts}}, conn), do: {:redirect, conn, opts}

    defp put_result(ctx, {:live, conn, view, html}), do: %{ctx | conn: conn, view: view, html: html}
    defp put_result(ctx, {:static, conn, html}), do: %{ctx | conn: conn, view: nil, html: html}
    # Mount-time redirects are followed in Task 4; until then they surface plainly.
    defp put_result(_ctx, {:redirect, _conn, opts}),
      do: raise("mount redirected to #{opts.to}; redirect following arrives in Task 4")
  end
end
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix test test/notary/conformance/live_view_test.exs`
Expected: PASS. If the spawned-process test fails with "LiveView helpers can only be invoked from the test process", `ensure_test_supervisor/0` isn't registering. Check `ExUnit.OnExitHandler.register/1` exists in the installed Elixir: `grep -n "def register" $(elixir -e 'IO.puts :code.lib_dir(:ex_unit)')/../ex_unit/lib/ex_unit/on_exit_handler.ex`, or locate `on_exit_handler.ex` in the Elixir source.

- [ ] **Step 8: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: all pass (the existing 288 tests + new).

```bash
git add mix.exs mix.lock lib/notary/config.ex lib/notary/conformance/live_view.ex lib/notary/conformance/live_view/ctx.ex test/support/web test/test_helper.exs test/notary/conformance/live_view_test.exs test/notary/config_test.exs
git commit -m "feat(liveview): mount/2 from any process, test endpoint

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Dom.decode/1`, the markup decoder

**Files:**
- Create: `lib/notary/conformance/live_view/dom.ex`
- Test: `test/notary/conformance/live_view/dom_test.exs`

**Interfaces:**
- Consumes: `Notary.Value.parse/1 :: {:ok, value} | {:error, {:unparseable_value, raw}}`; `Notary.Value.model/1`.
- Produces: `Notary.Conformance.LiveView.Dom.decode(String.t()) :: {:ok, %{String.t() => Notary.Value.t()}} | {:error, %{message: String.t(), variable: String.t() | nil}}`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Notary.Conformance.LiveView.DomTest do
  use ExUnit.Case, async: true

  alias Notary.Conformance.LiveView.Dom
  import Notary.Value, only: [model: 1, set: 1]

  defp var(name, attr, value), do: ~s(<span hidden data-notary-var="#{name}" #{attr}='#{value}'></span>)

  test "json: strings, integers, booleans, arrays as sequences, objects as records" do
    html =
      "<div>" <>
        var("s", "data-notary-json", ~s("payment")) <>
        var("i", "data-notary-json", "3") <>
        var("b", "data-notary-json", "true") <>
        var("q", "data-notary-json", ~s([1, "a"])) <>
        var("r", "data-notary-json", ~s({"k": 1})) <> "</div>"

    assert Dom.decode(html) ==
             {:ok, %{"s" => "payment", "i" => 3, "b" => true, "q" => [1, "a"], "r" => %{"k" => 1}}}
  end

  test "tla: sets and model values via Notary.Value" do
    html = var("users", "data-notary-value", "{u1, u2}") <> var("me", "data-notary-value", "u1")
    assert Dom.decode(html) == {:ok, %{"users" => set([model("u1"), model("u2")]), "me" => model("u1")}}
  end

  test "no markers is an empty projection" do
    assert Dom.decode("<div>nothing</div>") == {:ok, %{}}
  end

  test "works on a full document (a static page after a redirect)" do
    html = "<!DOCTYPE html><html><body>" <> var("page", "data-notary-json", ~s("plain")) <> "</body></html>"
    assert Dom.decode(html) == {:ok, %{"page" => "plain"}}
  end

  test "the same variable twice with the same value is fine" do
    html = var("s", "data-notary-json", ~s("a")) <> var("s", "data-notary-value", ~s("a"))
    assert Dom.decode(html) == {:ok, %{"s" => "a"}}
  end

  test "the same variable twice with different values names both" do
    html = var("s", "data-notary-json", ~s("a")) <> var("s", "data-notary-json", ~s("b"))
    assert {:error, %{variable: "s", message: message}} = Dom.decode(html)
    assert message =~ ~s("a")
    assert message =~ ~s("b")
  end

  test "both value attributes, or neither, is an error" do
    both = ~s(<span data-notary-var="s" data-notary-json='1' data-notary-value='1'></span>)
    neither = ~s(<span data-notary-var="s"></span>)
    assert {:error, %{variable: "s", message: m1}} = Dom.decode(both)
    assert m1 =~ "exactly one"
    assert {:error, %{variable: "s", message: m2}} = Dom.decode(neither)
    assert m2 =~ "exactly one"
  end

  test "json null, floats, and nested null/floats are errors" do
    for raw <- ["null", "1.5", "[1, null]", ~s({"k": 2.0})] do
      assert {:error, %{variable: "v", message: message}} = Dom.decode(var("v", "data-notary-json", raw))
      assert message =~ raw
    end
  end

  test "unparseable json or tla quotes the raw text" do
    assert {:error, %{variable: "v", message: m1}} = Dom.decode(var("v", "data-notary-json", "{nope"))
    assert m1 =~ "{nope"
    assert {:error, %{variable: "v", message: m2}} = Dom.decode(var("v", "data-notary-value", "<<<"))
    assert m2 =~ "<<<"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/notary/conformance/live_view/dom_test.exs`
Expected: FAIL, `Notary.Conformance.LiveView.Dom.decode/1 is undefined`.

- [ ] **Step 3: Implement**

```elixir
if Code.ensure_loaded?(LazyHTML) do
  defmodule Notary.Conformance.LiveView.Dom do
    @moduledoc """
    Decodes the `data-notary-var` markup convention (design spec §8.5) from
    rendered HTML into a projection. Each element carries `data-notary-var`
    and exactly one of `data-notary-json` (built-in `JSON`; no null or
    floats) or `data-notary-value` (TLC syntax, `Notary.Value.parse/1`).
    """

    @spec decode(String.t()) ::
            {:ok, %{String.t() => Notary.Value.t()}}
            | {:error, %{message: String.t(), variable: String.t() | nil}}
    def decode(html) when is_binary(html) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-notary-var]")
      |> Enum.map(&LazyHTML.attributes/1)
      |> Enum.reduce_while({:ok, %{}}, fn [attrs], {:ok, acc} ->
        attrs = Map.new(attrs)
        name = attrs["data-notary-var"]

        with {:ok, value} <- value(name, attrs),
             :ok <- no_conflict(acc, name, value) do
          {:cont, {:ok, Map.put(acc, name, value)}}
        else
          {:error, message} -> {:halt, {:error, %{variable: name, message: message}}}
        end
      end)
    end

    defp value(name, %{"data-notary-json" => raw} = attrs) when not is_map_key(attrs, "data-notary-value") do
      with {:ok, decoded} <- json(raw),
           :ok <- json_supported(decoded, raw) do
        {:ok, decoded}
      else
        _ -> {:error, "#{inspect(name)}: data-notary-json is not usable JSON (no null or floats): #{raw}"}
      end
    end

    defp value(name, %{"data-notary-value" => raw} = attrs) when not is_map_key(attrs, "data-notary-json") do
      case Notary.Value.parse(raw) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, "#{inspect(name)}: data-notary-value is not a TLA+ value: #{raw}"}
      end
    end

    defp value(name, _attrs),
      do: {:error, "#{inspect(name)}: needs exactly one of data-notary-json or data-notary-value"}

    defp json(raw) do
      {:ok, JSON.decode!(raw)}
    rescue
      _ -> :error
    end

    defp json_supported(v, _raw) when is_binary(v) or is_integer(v) or is_boolean(v), do: :ok
    defp json_supported(list, raw) when is_list(list), do: all_supported(list, raw)
    defp json_supported(map, raw) when is_map(map), do: all_supported(Map.values(map), raw)
    defp json_supported(_, _raw), do: :error

    defp all_supported(values, raw),
      do: if(Enum.all?(values, &(json_supported(&1, raw) == :ok)), do: :ok, else: :error)

    defp no_conflict(acc, name, value) do
      case Map.fetch(acc, name) do
        :error ->
          :ok

        {:ok, ^value} ->
          :ok

        {:ok, other} ->
          {:error,
           "#{inspect(name)} is rendered twice with different values: " <>
             "#{Notary.Value.to_tla(other)} and #{Notary.Value.to_tla(value)}"}
      end
    end
  end
end
```

Check that `Enum.map(&LazyHTML.attributes/1)` over a query result yields one single-element list per node. Iterating a `LazyHTML` yields one `LazyHTML` per node, and `attributes/1` returns `[[{k, v}, ...]]` for it. If iteration yields a different shape, use `LazyHTML.attributes(query_result)` directly, which returns one attribute list per node, and drop the `[attrs]` destructuring.

The two-different-values message uses `to_tla`, so `"a"`/`"b"` appear quoted, which is what the test asserts.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/notary/conformance/live_view/dom_test.exs`
Expected: PASS.

- [ ] **Step 5: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test`

```bash
git add lib/notary/conformance/live_view/dom.ex test/notary/conformance/live_view/dom_test.exs
git commit -m "feat(liveview): decode data-notary-var markup

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `click/2`, `submit/3`, `change/3`, `project_dom/1`, `project_assigns/2`

**Files:**
- Modify: `lib/notary/conformance/live_view.ex`
- Test: `test/notary/conformance/live_view_test.exs`

**Interfaces:**
- Consumes: `mount/2`, `Ctx` (Task 1); `Dom.decode/1` (Task 2).
- Produces:
  - `click(Ctx.t(), String.t())`, `submit(Ctx.t(), String.t(), map())` and `change(Ctx.t(), String.t(), map())`, each returning `{:ok, Ctx.t()} | {:rejected, {:not_available, String.t()}, Ctx.t()}`;
  - `project_dom(Ctx.t()) :: %{String.t() => Notary.Value.t()}`, which throws `{:notary_fail, :invalid_projection, %{message:, variable:}}`;
  - `project_assigns(Ctx.t(), [atom()]) :: %{String.t() => term()}`.
  - A private `act/2`, which Task 4 extends with redirect following.

- [ ] **Step 1: Write the failing tests**

Append to `Notary.Conformance.LiveViewTest`:

```elixir
  defp toggle do
    {:ok, ctx} = mount(ToggleLive, endpoint: Endpoint)
    ctx
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
      assert_raise Notary.Error, ~r/\.dup.*2 elements/, fn -> click(toggle(), ".dup") end
    end
  end

  describe "submit/3 and change/3" do
    test "submit sends the values" do
      assert {:ok, ctx} = submit(toggle(), "#name-form", %{name: "ada"})
      assert project_dom(ctx)["name"] == "ada"
    end

    test "a form whose only submit button is disabled is not available" do
      {:ok, ctx} = click(toggle(), "#lock")
      assert {:rejected, {:not_available, "#name-form"}, _} = submit(ctx, "#name-form", %{name: "x"})
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
      ctx = %{toggle() | view: nil, html: ~s(<span data-notary-var="x"></span>)}
      assert {:notary_fail, :invalid_projection, %{variable: "x", message: _}} = catch_throw(project_dom(ctx))
    end

    test "project_assigns reads the given assigns as string keys" do
      {:ok, ctx} = click(toggle(), "#flip")
      assert project_assigns(ctx, [:on, :name]) == %{"on" => true, "name" => ""}
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/notary/conformance/live_view_test.exs`
Expected: FAIL, `click/2 undefined` (and similar).

- [ ] **Step 3: Implement**

Add to `Notary.Conformance.LiveView`:

```elixir
    @submit_buttons "button:not([type]), button[type=submit], input[type=submit]"

    @doc """
    Clicks the element matching `selector`. Returns
    `{:rejected, {:not_available, selector}, ctx}` without sending an event
    when the element is missing or `disabled` (design spec §8.3/§8.4).
    """
    @spec click(Ctx.t(), String.t()) ::
            {:ok, Ctx.t()} | {:rejected, {:not_available, String.t()}, Ctx.t()}
    def click(%Ctx{} = ctx, selector) do
      with {:ok, _node} <- available(ctx, selector, :click) do
        act(ctx, fn view -> view |> Phoenix.LiveViewTest.element(selector) |> Phoenix.LiveViewTest.render_click() end)
      end
    end

    @doc "Submits the form matching `selector` with `values`. Unavailable if missing, disabled, or every submit button is disabled."
    @spec submit(Ctx.t(), String.t(), map()) ::
            {:ok, Ctx.t()} | {:rejected, {:not_available, String.t()}, Ctx.t()}
    def submit(%Ctx{} = ctx, selector, values) do
      with {:ok, _node} <- available(ctx, selector, :submit) do
        act(ctx, fn view -> view |> Phoenix.LiveViewTest.form(selector, values) |> Phoenix.LiveViewTest.render_submit() end)
      end
    end

    @doc "Sends a change event for the form matching `selector`. Unavailable if missing or disabled."
    @spec change(Ctx.t(), String.t(), map()) ::
            {:ok, Ctx.t()} | {:rejected, {:not_available, String.t()}, Ctx.t()}
    def change(%Ctx{} = ctx, selector, values) do
      with {:ok, _node} <- available(ctx, selector, :change) do
        act(ctx, fn view -> view |> Phoenix.LiveViewTest.form(selector, values) |> Phoenix.LiveViewTest.render_change() end)
      end
    end

    @doc """
    Projects the `data-notary-var` markup of the current view (or static
    page). A bad marker throws `:invalid_projection` for the runner.
    """
    @spec project_dom(Ctx.t()) :: %{String.t() => Notary.Value.t()}
    def project_dom(%Ctx{} = ctx) do
      case Notary.Conformance.LiveView.Dom.decode(current_html(ctx)) do
        {:ok, projection} -> projection
        {:error, details} -> throw({:notary_fail, :invalid_projection, details})
      end
    end

    @doc """
    Escape hatch: reads `keys` from the LiveView's socket assigns, returned
    with string keys. Depends on LiveView internals (the channel process's
    state); prefer `project_dom/1`.
    """
    @spec project_assigns(Ctx.t(), [atom()]) :: %{String.t() => term()}
    def project_assigns(%Ctx{view: view}, keys) when not is_nil(view) do
      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
      Map.new(keys, &{Atom.to_string(&1), Map.fetch!(assigns, &1)})
    end

    defp current_html(%Ctx{view: nil, html: html}), do: html
    defp current_html(%Ctx{view: view}), do: Phoenix.LiveViewTest.render(view)

    defp available(%Ctx{view: nil} = ctx, selector, _kind), do: {:rejected, {:not_available, selector}, ctx}

    defp available(%Ctx{} = ctx, selector, kind) do
      nodes = ctx |> current_html() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

      case Enum.count(nodes) do
        0 ->
          {:rejected, {:not_available, selector}, ctx}

        1 ->
          if enabled?(nodes, kind), do: {:ok, nodes}, else: {:rejected, {:not_available, selector}, ctx}

        n ->
          raise Notary.Error.new(
                  :invalid_mapping,
                  "selector #{inspect(selector)} matches #{n} elements; Notary.Conformance.LiveView helpers need exactly one"
                )
      end
    end

    defp enabled?(node, kind) do
      disabled? = LazyHTML.attribute(node, "disabled") != []

      cond do
        disabled? -> false
        kind != :submit -> true
        true -> submit_enabled?(LazyHTML.query(node, @submit_buttons))
      end
    end

    # No submit button at all: still submittable (Enter in a field).
    defp submit_enabled?(buttons) do
      Enum.count(buttons) == 0 or Enum.any?(buttons, &(LazyHTML.attribute(&1, "disabled") == []))
    end

    defp act(%Ctx{view: view} = ctx, fun) do
      case fun.(view) do
        html when is_binary(html) ->
          Phoenix.LiveViewTest.render_async(view, Notary.Config.get(:settle_timeout))
          {:ok, ctx}
      end
    end
```

`render_async/2` is given an explicit timeout. Its default reads `:ex_unit`'s `assert_receive_timeout` env, which is missing under `mix notary.verify`.

If the message regex in the `.dup` test doesn't match ("matches 2 elements"), adjust the test regex to `~r/"\.dup" matches 2 elements/` rather than changing the message.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/notary/conformance/live_view_test.exs`
Expected: PASS. If `LazyHTML.query(node, ...)` on a single-node `LazyHTML` returns its descendants (it should), `submit_enabled?` sees only that form's buttons.

- [ ] **Step 5: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test`

```bash
git add lib/notary/conformance/live_view.ex test/notary/conformance/live_view_test.exs
git commit -m "feat(liveview): click/submit/change with availability, project_dom

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Following redirects

**Files:**
- Modify: `lib/notary/conformance/live_view.ex` (`act/2`, `put_result/2`)
- Test: `test/notary/conformance/live_view_test.exs`

**Interfaces:**
- Consumes: `visit/3`, `put_result/2`, `act/2` (Tasks 1 and 3); routes `/toggle`, `/done`, `/plain` (Task 1).
- Produces: helpers that follow `{:error, {:live_redirect | :redirect, %{to: to}}}`, up to 5 hops. A LiveView target replaces `view`; anything else sets `view: nil, html: body`.

- [ ] **Step 1: Write the failing tests**

```elixir
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
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/notary/conformance/live_view_test.exs --only describe:redirects`
Expected: FAIL with a `CaseClauseError` in `act/2` on `{:error, {:live_redirect, ...}}`.

- [ ] **Step 3: Implement**

Replace `act/2` and the redirect clause of `put_result/2`:

```elixir
    @max_redirects 5

    defp act(%Ctx{view: view} = ctx, fun) do
      case fun.(view) do
        html when is_binary(html) ->
          Phoenix.LiveViewTest.render_async(view, Notary.Config.get(:settle_timeout))
          {:ok, ctx}

        {:error, {kind, %{to: _} = opts}} when kind in [:live_redirect, :redirect] ->
          {:ok, put_result(ctx, {:redirect, ctx.conn, opts})}
      end
    end

    defp put_result(ctx, result, hops \\ @max_redirects)

    defp put_result(ctx, {:live, conn, view, html}, _hops),
      do: %{ctx | conn: conn, view: view, html: html}

    defp put_result(ctx, {:static, conn, html}, _hops), do: %{ctx | conn: conn, view: nil, html: html}

    defp put_result(ctx, {:redirect, conn, opts}, hops) when hops > 0 do
      {conn, to} = Phoenix.LiveViewTest.__follow_redirect__(conn, ctx.endpoint, nil, opts)
      put_result(ctx, visit(conn, ctx.endpoint, to), hops - 1)
    end

    defp put_result(_ctx, {:redirect, _conn, opts}, 0),
      do: raise(Notary.Error.new(:invalid_mapping, "more than #{@max_redirects} redirects in a row (last to #{opts.to})"))
```

Remove the Task 1 placeholder clause that raised "redirect following arrives in Task 4".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/notary/conformance/live_view_test.exs`
Expected: PASS.

- [ ] **Step 5: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test`

```bash
git add lib/notary/conformance/live_view.ex test/notary/conformance/live_view_test.exs
git commit -m "feat(liveview): follow live and plain redirects

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The runner rule `:action_not_offered`

**Files:**
- Modify: `lib/notary/conformance/runner.ex` (rejected branch of `walk/5`, `@spec_level_kinds`)
- Modify: `lib/notary/conformance/failure.ex` (type and explanation)
- Modify: `lib/notary/diagnostic.ex` (build, builder, headline, moduledoc kind list)
- Modify: `test/support/fixtures/counter_specs.ex` (`CounterNotOfferedSpec`)
- Test: `test/notary/conformance/runner_test.exs`, `test/notary/diagnostic_test.exs`

**Interfaces:**
- Consumes: `Walk.closure/3` and `StateGraph.successors/3` (existing).
- Produces:
  - `%Failure{kind: :action_not_offered, details: %{selector: String.t()}}` (`selector` is present only for `{:not_available, sel}`);
  - `Failure.explanation(:action_not_offered)`.

- [ ] **Step 1: Add the fixture mapping**

Append to `test/support/fixtures/counter_specs.ex`:

```elixir
defmodule Notary.Fixtures.CounterNotOfferedSpec do
  @moduledoc false
  # Bug: the "UI" never offers Inc, although the spec allows it below Max.
  use Notary.Conformance, spec: "test/fixtures/specs/Counter.tla", discover: false

  def init, do: Agent.start_link(fn -> 0 end)
  def actions, do: %{"Inc" => StreamData.constant(%{}), "Reset" => StreamData.constant(%{})}
  def action("Inc", _, pid), do: {:rejected, {:not_available, "#inc"}, pid}

  def action("Reset", _, pid) do
    Agent.update(pid, fn _ -> 0 end)
    {:ok, pid}
  end

  def project(pid), do: %{"x" => Agent.get(pid, & &1)}
end
```

- [ ] **Step 2: Write the failing runner tests**

Append to `test/notary/conformance/runner_test.exs`:

```elixir
  describe "action_not_offered (design spec §8.4)" do
    test "a :not_available rejection of an action the spec allows everywhere here fails" do
      assert {:error, %Failure{kind: :action_not_offered, details: details, steps: steps}} =
               check(Fixtures.CounterNotOfferedSpec, "Counter")

      assert details.selector == "#inc"
      assert List.last(steps).action == "Inc"
      assert List.last(steps).outcome == {:rejected, {:not_available, "#inc"}}
    end

    test "other rejection reasons keep the old semantics" do
      assert {:ok, _} = check(Fixtures.CounterSpec, "Counter")
    end

    test "passes when only some candidates enable the action (hidden variable)" do
      assert {:ok, _} =
               Runner.check(Notary.Conformance.RunnerTest.HiddenGo, hidden_graph(), ["x"],
                 seed: 1,
                 max_runs: 30
               )
    end

    test "fails when every candidate enables it" do
      assert {:error, %Failure{kind: :action_not_offered}} =
               Runner.check(Notary.Conformance.RunnerTest.HiddenGo, hidden_graph(both_go: true), ["x"],
                 seed: 1,
                 max_runs: 30
               )
    end
  end

  defp hidden_graph(opts \\ []) do
    extra =
      if opts[:both_go],
        do: ~s(2 -> 3 [label="Go",color="black",fontcolor="black"];\n),
        else: ""

    dot = """
    strict digraph DiskGraph {
    nodesep=0.35;
    subgraph cluster_graph {
    color="white";
    1 [label="/\\\\ h = 0\\n/\\\\ x = 0",style = filled]
    2 [label="/\\\\ h = 1\\n/\\\\ x = 0",style = filled]
    3 [label="/\\\\ h = 0\\n/\\\\ x = 1"]
    1 -> 3 [label="Go",color="black",fontcolor="black"];
    #{extra}}
    }
    """

    {:ok, graph} = Notary.StateGraph.parse_dot(dot)
    graph
  end
```

And, at the bottom of the test file (outside the test module):

```elixir
defmodule Notary.Conformance.RunnerTest.HiddenGo do
  @moduledoc false
  # Never offers Go. With observe: ["x"], x = 0 leaves candidates h = 0 (Go
  # enabled) and h = 1 (Go not enabled, unless both_go).
  use Notary.Conformance, spec: "unused.tla", observe: ["x"], discover: false, generation: :uniform

  def init, do: {:ok, nil}
  def actions, do: %{"Go" => StreamData.constant(%{})}
  def action("Go", _, ctx), do: {:rejected, {:not_available, "#go"}, ctx}
  def project(_), do: %{"x" => 0}
end
```

Check that the DOT escaping produces labels like the real files (`/\\ h = 0\n/\\ x = 0` on disk, i.e. backslash-backslash, then a literal `\n`). If `parse_dot` rejects it, print `File.read!("test/fixtures/graphs/Bank.dot") |> String.slice(0, 300)` and match its bytes exactly. Inside a heredoc, `\\\\` yields `\\` and `\\n` yields `\n`.

- [ ] **Step 3: Write the failing diagnostic test**

Append to `test/notary/diagnostic_test.exs`, next to the `action_not_enabled` test:

```elixir
  test "action_not_offered points at the guard that made it enabled and names the selector" do
    text = render(Fixtures.CounterNotOfferedSpec, "Counter")

    assert text =~ "error[action_not_offered]"
    assert text =~ "Inc was not offered, but the spec allows it in x = "
    assert text =~ "test/fixtures/specs/Counter.tla:10:11"
    assert text =~ "true here: x = "
    assert text =~ "help: the UI must offer Inc here; \"#inc\" was missing or disabled"
  end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `mix test test/notary/conformance/runner_test.exs test/notary/diagnostic_test.exs`
Expected: the new tests FAIL. `CounterNotOfferedSpec` passes conformance today, because rejection with unchanged state is legal. The diagnostic has no `action_not_offered` clause.

- [ ] **Step 5: Implement the runner rule**

In `lib/notary/conformance/runner.ex`, add `:action_not_offered` to `@spec_level_kinds`. In `walk/5`'s `{:rejected, reason, ctx}` branch, replace the final `if next == [] ...` with:

```elixir
        cond do
          not_available?(reason) and offered_everywhere?(graph, closed, name) ->
            {{:fail, :action_not_offered, not_offered_details(reason)}, ctx, i, []}

          next == [] ->
            {{:fail, :rejected_with_side_effect, %{}}, ctx, i, []}

          true ->
            walk(w, rest, i + 1, ctx, next)
        end
```

Add these private helpers near `observed/3`:

```elixir
  # Design spec §8.4: a UI must offer what the spec allows. Only when *every*
  # candidate enables the action (hidden variables can leave candidates that
  # disagree, and then the UI may legitimately not offer it).
  defp not_available?(:not_available), do: true
  defp not_available?({:not_available, _}), do: true
  defp not_available?(_), do: false

  defp offered_everywhere?(graph, closed, name),
    do: Enum.all?(closed, &(StateGraph.successors(graph, &1, name) != []))

  defp not_offered_details({:not_available, selector}), do: %{selector: selector}
  defp not_offered_details(:not_available), do: %{}
```

In the moduledoc of `minimize/4`, add `:action_not_offered` to the parenthesised spec-level list.

In `lib/notary/conformance/failure.ex`, add `| :action_not_offered` to `@type kind` and this to `@explanations`:

```elixir
    action_not_offered:
      "The spec allows this action here, but the UI did not offer it (the element was missing or disabled).",
```

- [ ] **Step 6: Implement the diagnostic**

In `lib/notary/diagnostic.ex`:

Add a dispatch clause after the `:action_not_enabled` one:

```elixir
  defp build(%Failure{kind: :action_not_offered} = f, spec, _mapping),
    do: action_not_offered(f, spec)
```

Add the builder after `action_not_enabled/2`:

```elixir
  # -- action_not_offered (design spec §8.4) ---------------------------------------

  defp action_not_offered(f, spec) do
    with {:ok, rel, text} <- spec_source(spec),
         action when is_binary(action) <- List.last(f.steps).action,
         %{} = def_ <- SpecLocate.definition(text, action) do
      guards = Enum.filter(def_.conjuncts, &(&1.kind == :guard))
      state = pre_state(f)

      labels =
        case guards do
          [] ->
            [definition_fallback_label(def_, text, "enabled in #{format_state(state)}")]

          several ->
            Enum.map(several, &conjunct_label(&1, :primary, "true here: #{format_state(state)}"))
        end

      what = if f.details[:selector], do: "#{inspect(f.details.selector)} was", else: "it was"

      report =
        f
        |> base_report(rel)
        |> PReport.with_labels(labels)
        |> PReport.with_help("the UI must offer #{action} here; #{what} missing or disabled")

      {report, %{rel => text}}
    else
      _ -> nil
    end
  end
```

Here every guard *is* true, since the action is enabled in every candidate. That's why each guard gets the "true here" label, unlike `action_not_enabled`, which never claims which of several guards is false.

Add a headline after the `:action_not_enabled` one:

```elixir
  defp headline(%Failure{kind: :action_not_offered} = f) do
    action = List.last(f.steps).action || "the action"
    "#{action} was not offered, but the spec allows it in #{format_state(pre_state(f))}"
  end
```

In the moduledoc list of spec-only kinds (around line 34), add `action_not_offered`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix test test/notary/conformance/runner_test.exs test/notary/diagnostic_test.exs`
Expected: PASS. If the diagnostic test's `pre_state` reads a step that isn't the one before the rejection, check `Enum.at(f.steps, -2)`. The failure's steps end with the rejected step, so `-2` is the state it was rejected in, as for `action_not_enabled`.

- [ ] **Step 8: Check the JSON and text reports carry the selector**

Run: `mix test test/notary/report_test.exs`
Expected: PASS, with no changes needed, because `Report` renders `details` generically. In the first test from Step 2, bind the failure (`assert {:error, %Failure{...} = failure} = ...`) and add `assert Notary.Report.format_failure("Counter", failure) =~ "selector: \"#inc\""`. If the generic details line renders the selector differently, for example unquoted, match what `format_failure/3` actually prints; don't change `Report`.

- [ ] **Step 9: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test`

```bash
git add lib/notary/conformance/runner.ex lib/notary/conformance/failure.ex lib/notary/diagnostic.ex test/support/fixtures/counter_specs.ex test/notary/conformance/runner_test.exs test/notary/diagnostic_test.exs
git commit -m "feat(conformance): action_not_offered, a UI must offer what the spec allows

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `Wizard.tla`, written with the human (HUMAN GATE)

**Files:**
- Create: `test/fixtures/specs/Wizard.tla`, `test/fixtures/specs/Wizard.cfg`
- Modify: `test/fixtures/regen_graphs.exs` (add `Wizard`)
- Create: `test/fixtures/graphs/Wizard.dot` (generated)

**Interfaces:**
- Produces: spec variables `step` (`"address" | "payment" | "done"`) and `address` (`BOOLEAN`), and actions `EnterAddress`, `Continue`, `Back`, `Pay`, `StartOver`. **If the human renames or reshapes anything, Task 7's mapping and LiveView must follow the spec as written. Record the final names in this task's commit message.**

- [ ] **Step 1: Present this draft to the human and ask them to edit it.** Do not write the file until they approve the text. This is the starting point:

```tla
---- MODULE Wizard ----
\* A three-step checkout wizard: enter an address, review payment, done.
\* Pay must only be possible on the payment step, after an address exists.
VARIABLES step, address

vars == <<step, address>>

TypeOK == /\ step \in {"address", "payment", "done"}
          /\ address \in BOOLEAN

Init == /\ step = "address"
        /\ address = FALSE

EnterAddress == /\ step = "address"
                /\ address' = TRUE
                /\ UNCHANGED step

Continue == /\ step = "address"
            /\ address
            /\ step' = "payment"
            /\ UNCHANGED address

Back == /\ step = "payment"
        /\ step' = "address"
        /\ UNCHANGED address

Pay == /\ step = "payment"
       /\ address
       /\ step' = "done"
       /\ UNCHANGED address

StartOver == /\ step = "done"
             /\ step' = "address"
             /\ address' = FALSE

Next == EnterAddress \/ Continue \/ Back \/ Pay \/ StartOver

Spec == Init /\ [][Next]_vars
====
```

```
INIT Init
NEXT Next
INVARIANT TypeOK
```

Points to raise with the human:
- The action is called `Continue`, not `Next`, because `Next` is the next-state relation.
- `StartOver` keeps `done` from deadlocking TLC.
- `EnterAddress` stays enabled after an address exists (a self-loop), which matches a form that's still on screen.

- [ ] **Step 2: Write the approved text and model-check it**

Run: `mix run -e '{:ok, s} = Notary.Spec.fetch("Wizard", "test/fixtures/specs"); IO.inspect(Notary.TLC.check(s, []))'`. `mix notary.check` only looks in the configured specs directory.
Expected: no errors. With the draft: 4 distinct states.

- [ ] **Step 3: Generate the graph fixture**

In `test/fixtures/regen_graphs.exs`, change `~w(Counter Bank Workflow Async)` to `~w(Counter Bank Workflow Async Wizard)`.

Run: `mix run test/fixtures/regen_graphs.exs`
Expected: `Wizard: 4 states -> .../test/fixtures/graphs/Wizard.dot` (for the draft spec). The other graphs regenerate unchanged. Confirm with `git diff --stat test/fixtures/graphs`, which should show only `Wizard.dot` as new.

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/specs/Wizard.tla test/fixtures/specs/Wizard.cfg test/fixtures/regen_graphs.exs test/fixtures/graphs/Wizard.dot
git commit -m "spec: Wizard fixture spec (human-authored)

Variables: step, address. Actions: EnterAddress, Continue, Back, Pay, StartOver.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Wizard fixtures, conformance tests and measured catch rates

**Files:**
- Create: `test/support/fixtures/wizard_live.ex`
- Create: `test/support/fixtures/wizard_specs.ex`
- Modify: `test/support/web/router.ex` (wizard routes)
- Create: `test/fixtures/measure_wizard.exs`
- Test: `test/notary/conformance/runner_test.exs`

**Interfaces:**
- Consumes:
  - from Tasks 1 to 4: `mount/2`, `click/2`, `submit/3`, `project_dom/1`, `unmount/1`, `Notary.Fixtures.Web.Endpoint`, `Notary.Fixtures.Web.start!/0`;
  - from Task 5: `:action_not_offered`;
  - from Task 6: `Wizard.dot` and its names.
- Produces: `Notary.Fixtures.WizardSpec`, `WizardEarlyPaySpec`, `WizardNoPaySpec`, `WizardRedirectSpec`.

- [ ] **Step 1: Write the wizard LiveViews**

`test/support/fixtures/wizard_live.ex`:

```elixir
defmodule Notary.Fixtures.WizardLive do
  @moduledoc false
  # session "variant": "correct" | "early_pay" (Pay shown on the address step
  # too) | "no_pay" (Pay never rendered) | "redirect" (Pay navigates to
  # /wizard/done). Routed at /wizard as "redirect".
  use Phoenix.LiveView

  def mount(_params, session, socket) do
    variant = session["variant"] || "redirect"
    {:ok, assign(socket, variant: variant, step: "address", address: false)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <span hidden data-notary-var="step" data-notary-json={JSON.encode!(@step)}></span>
      <span hidden data-notary-var="address" data-notary-json={JSON.encode!(@address)}></span>
      <form :if={@step == "address"} id="address-form" phx-submit="enter_address">
        <input name="address" value="" />
        <button type="submit">Save address</button>
      </form>
      <button :if={@step == "address"} id="continue" phx-click="continue" disabled={not @address}>
        Continue
      </button>
      <button :if={@step == "payment"} id="back" phx-click="back">Back</button>
      <button :if={show_pay?(@variant, @step)} id="pay" phx-click="pay">Pay</button>
      <button :if={@step == "done"} id="start-over" phx-click="start_over">Start over</button>
    </div>
    """
  end

  defp show_pay?("early_pay", step), do: step in ["address", "payment"]
  defp show_pay?("no_pay", _step), do: false
  defp show_pay?(_variant, step), do: step == "payment"

  def handle_event("enter_address", %{"address" => _}, socket), do: {:noreply, assign(socket, address: true)}
  def handle_event("continue", _, socket), do: {:noreply, assign(socket, step: "payment")}
  def handle_event("back", _, socket), do: {:noreply, assign(socket, step: "address")}
  def handle_event("start_over", _, socket), do: {:noreply, assign(socket, step: "address", address: false)}

  def handle_event("pay", _, %{assigns: %{variant: "redirect"}} = socket),
    do: {:noreply, push_navigate(socket, to: "/wizard/done")}

  def handle_event("pay", _, socket), do: {:noreply, assign(socket, step: "done")}
end

defmodule Notary.Fixtures.WizardDoneLive do
  @moduledoc false
  # The redirect variant's confirmation page: step "done", address TRUE.
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <div>
      <span hidden data-notary-var="step" data-notary-json={JSON.encode!("done")}></span>
      <span hidden data-notary-var="address" data-notary-json={JSON.encode!(true)}></span>
      <button id="start-over" phx-click="start_over">Start over</button>
    </div>
    """
  end

  def handle_event("start_over", _, socket), do: {:noreply, push_navigate(socket, to: "/wizard")}
end
```

In `test/support/web/router.ex`, inside the scope, add:

```elixir
    live "/wizard", Notary.Fixtures.WizardLive
    live "/wizard/done", Notary.Fixtures.WizardDoneLive
```

- [ ] **Step 2: Write the mappings**

`test/support/fixtures/wizard_specs.ex`:

```elixir
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
  def actions, do: Map.new(~w(EnterAddress Continue Back Pay StartOver), &{&1, StreamData.constant(%{})})

  @impl true
  def action("EnterAddress", _, ctx), do: submit(ctx, "#address-form", %{address: "1 Main St"})
  def action("Continue", _, ctx), do: click(ctx, "#continue")
  def action("Back", _, ctx), do: click(ctx, "#back")
  def action("Pay", _, ctx), do: click(ctx, "#pay")
  def action("StartOver", _, ctx), do: click(ctx, "#start-over")

  @impl true
  def project(ctx), do: project_dom(ctx)

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
```

The early-Pay fixture: when Pay is clicked on the address step, the step becomes `"done"`. The spec doesn't enable Pay there, so the runner reports `:action_not_enabled`. The no-Pay fixture: on the payment step, Pay is enabled in the only candidate, so `{:not_available, "#pay"}` gives `:action_not_offered`.

- [ ] **Step 3: Write the failing conformance tests**

Append to `test/notary/conformance/runner_test.exs`:

```elixir
  describe "LiveView wizard (design spec §8, §11)" do
    test "the correct wizard passes with full action coverage" do
      assert {:ok, %{coverage: coverage}} = check(Fixtures.WizardSpec, "Wizard")
      assert coverage.actions.unreached == []
    end

    test "the routed wizard (redirects) passes" do
      assert {:ok, _} = check(Fixtures.WizardRedirectSpec, "Wizard", max_runs: 50)
    end

    test "Pay offered before the payment step fails with action_not_enabled" do
      assert {:error, %Failure{kind: :action_not_enabled, steps: steps}} =
               check(Fixtures.WizardEarlyPaySpec, "Wizard")

      assert List.last(steps).action == "Pay"
    end

    test "Pay never offered fails with action_not_offered and the selector" do
      assert {:error, %Failure{kind: :action_not_offered, details: %{selector: "#pay"}}} =
               check(Fixtures.WizardNoPaySpec, "Wizard")
    end
  end
```

- [ ] **Step 4: Run the tests and check their state**

Run: `mix test test/notary/conformance/runner_test.exs --only describe:"LiveView wizard (design spec §8, §11)"`
Expected: PASS. The tests and fixtures arrive together, and the earlier tasks did the real work. If any fail:
- read the failure report (step table and diagnostic) before changing anything;
- a fixture LiveView that disagrees with the human's spec is fixed in the LiveView, never in the spec.

Then prove the buggy fixtures are what fail. Temporarily change `WizardNoPaySpec.init` to `mount_variant("correct")`, run the test, see it FAIL ("expected action_not_offered, got {:ok, ...}"), and revert. Do the same for `WizardEarlyPaySpec`.

- [ ] **Step 5: Measure catch rates**

`test/fixtures/measure_wizard.exs`:

```elixir
# Catch rates for the buggy wizards over seeds 1..10 at the default 100 runs.
# Run: MIX_ENV=test mix run test/fixtures/measure_wizard.exs
Notary.Fixtures.Web.start!()
graph = Notary.Fixtures.graph("Wizard")

for {module, expected} <- [
      {Notary.Fixtures.WizardEarlyPaySpec, :action_not_enabled},
      {Notary.Fixtures.WizardNoPaySpec, :action_not_offered}
    ] do
  caught =
    Enum.count(1..10, fn seed ->
      match?(
        {:error, %Notary.Conformance.Failure{kind: ^expected}},
        Notary.Conformance.check(module, graph, seed: seed, max_runs: 100)
      )
    end)

  IO.puts("#{inspect(module)}: #{expected} on #{caught}/10 seeds")
end
```

Run: `MIX_ENV=test mix run test/fixtures/measure_wizard.exs`
Expected: both bugs on 10/10 seeds; they're each one or two steps from the initial state. Record the exact output for Task 8.

This script also exercises Review Focus 1: it runs outside ExUnit's runner, so `mount/2` must register its own test supervisor. If it fails with "can only be invoked from the test process", fix `ensure_test_supervisor/0`.

- [ ] **Step 6: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test`

```bash
git add test/support/fixtures/wizard_live.ex test/support/fixtures/wizard_specs.ex test/support/web/router.ex test/fixtures/measure_wizard.exs test/notary/conformance/runner_test.exs
git commit -m "test(liveview): wizard fixtures (correct, early pay, no pay, redirect)

Measured: <paste the two lines from measure_wizard.exs>

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Docs (guide, README, template)

**Files:**
- Create: `guides/liveview.md`
- Modify: `mix.exs` (`docs` extras)
- Modify: `README.md`
- Modify: `priv/templates/mapping.ex.eex`

**Interfaces:**
- Consumes: everything above; the measured numbers from Task 7 Step 5.

- [ ] **Step 1: Write `guides/liveview.md`**

Sections, in order. Each has real code taken from the Task 7 fixtures, with module names changed to `MyAppWeb.*`:

1. **What you get.** Two rules, stated plainly:
   - the UI must not offer what the spec forbids (`action_not_enabled`);
   - it must offer what the spec allows (`action_not_offered`).
2. **Setup.**
   - `{:phoenix_live_view, ...}` is already in a Phoenix app.
   - `lazy_html` is in `:test` (Phoenix 1.8 generators add it).
   - `config :notary, endpoint: MyAppWeb.Endpoint` in `config/test.exs`.
3. **The spec.** The Wizard spec as the human finalised it in Task 6, verbatim, with a short paragraph per action.
4. **Markup.**
   - `data-notary-var` with `data-notary-json` or `data-notary-value`;
   - why there's no Notary helper in templates (Notary is `:dev`/`:test`);
   - `hidden` keeps the markers invisible.
   - **Ask the human:** should markers be rendered only in dev/test? An optional tip is a compile-time flag `Application.compile_env(:my_app, :notary_markers, false)` around the markers. Include it only if they want it.
5. **The mapping.** `WizardSpec` from Task 7, and `mount/2` with a module vs a path.
6. **Running it.** `mix notary.check Wizard`, then `mix notary.test Wizard`.
7. **Break it.** The early-Pay and no-Pay variants: what each failure looks like, pasted from real output (`mix test` the two buggy tests with the diagnostic rendered, or `mix notary.test` in a scratch app).
8. **Limits.**
   - one view and one actor;
   - no PubSub from other processes yet;
   - no JS hooks;
   - `project_assigns/2` depends on internals;
   - the helpers use undocumented LiveViewTest functions.

- [ ] **Step 2: Wire it into the docs**

In `mix.exs` `docs/0`, `extras:` becomes `["README.md", "guides/getting-started.md", "guides/rate-limiter.md", "guides/liveview.md"]`.

Run: `mix docs`
Expected: builds with no warnings about `guides/liveview.md`.

- [ ] **Step 3: README section**

After "## The mapping module" / "### Generation", add "### LiveView". It needs:
- a 6-line mapping example;
- the two rules;
- the markup line;
- a link to the guide;
- the measured catch rates from Task 7 Step 5, in the same style as the TLCRunner numbers in "Limits".

In "## Limits (v1)", change the LiveView mention to "single view, single actor (Phase 2a)".

- [ ] **Step 4: Template hint**

In `priv/templates/mapping.ex.eex`, after the existing `init` stub, add a comment block:

```elixir
  # Driving a LiveView? import Notary.Conformance.LiveView and use:
  #   def init, do: mount(MyAppWeb.SomeLive, endpoint: MyAppWeb.Endpoint)
  #   def action("Pay", _, ctx), do: click(ctx, "#pay")
  #   def project(ctx), do: project_dom(ctx)
  #   def teardown(ctx), do: unmount(ctx)
  # See the LiveView guide.
```

Run: `mix test test/notary/scaffold_test.exs`
Expected: PASS. If a test snapshots the template output exactly, update the expected text to include the comment.

- [ ] **Step 5: Final gates and commit**

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test && mix notary.verify`
Expected: everything passes. `notary.verify` still covers only Notary's own `specs/`.

```bash
git add guides/liveview.md mix.exs README.md priv/templates/mapping.ex.eex
git commit -m "docs: LiveView guide, README section, mapping template hint

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
