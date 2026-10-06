# LiveView: A Checkout Wizard

This guide verifies a Phoenix LiveView against a spec. It assumes you've
worked through [Getting Started: Hello, World](getting-started.md), so
project setup, `mix notary.new`, and the overall workflow are only sketched
here. What's new is **driving a LiveView** instead of calling functions
directly.

The feature is a three-step checkout wizard: enter an address, review on the
payment step, pay. It's small, but it's enough to show the one thing LiveView
conformance adds over ordinary mappings: checking not just what your code
*does*, but what your UI *offers*.

## 1. What you get

`Notary.Conformance.LiveView` is a set of helpers on the mapping module you
already know from Getting Started — not a separate runner, not a declarative
action table. Importing it gets you two rules, both enforced automatically:

- **The UI must not offer what the spec forbids.** This is the same
  `action_not_enabled` check every mapping gets: if your code accepts an
  action the spec doesn't allow in that state, conformance fails.
- **The UI must also offer what the spec allows.** This is new. If an element
  is missing or `disabled` and the spec says the action should be possible
  here, conformance fails with `action_not_offered` — a UI bug ordinary
  function-level mappings can't even express, because there's no "button" to
  forget to enable.

## 2. Setup

If you're in a Phoenix 1.8+ app, most of this is already true:

- `{:phoenix_live_view, "~> 1.2"}` is already a dependency.
- `{:lazy_html, ...}`, scoped to `:test`, is already a dependency — Phoenix
  1.8's generators add it for `LiveViewTest`'s `has_element?/2` and friends,
  which Notary's LiveView helpers also use.

One thing to add, in `config/test.exs`:

```elixir
config :notary, endpoint: MyAppWeb.Endpoint
```

`mount/2` needs an endpoint to build a connection against. Setting it once in
config means your mapping's `init/0` doesn't have to pass `endpoint:` on
every call (you still can, to override it).

The helpers exist only when both `phoenix_live_view` and `lazy_html` are
available in the environment Notary is compiled in (usually `:test`).
Otherwise `Notary.Conformance.LiveView` is never defined, and a mapping that
imports it fails with "module Notary.Conformance.LiveView is not available".

Nothing in your application's own templates needs to depend on Notary: see
"Observing the page" below — Notary reads your normal, visible markup.

## 3. The spec

`specs/Wizard.tla`, exactly as reviewed and locked (see Getting Started for
`mix notary.check` / `mix notary.lock`):

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

What each action means for the UI:

- **`EnterAddress`** — only on the address step; records that an address now
  exists. It doesn't change `step`, so the UI stays on the address step
  afterward.
- **`Continue`** — moves from the address step to the payment step, but only
  once `address` is true. A UI that lets you continue before entering an
  address violates this guard (`action_not_enabled`); a UI that disables
  "Continue" even after the address is entered violates the availability
  rule (`action_not_offered`).
- **`Back`** — moves from the payment step back to the address step
  unconditionally.
- **`Pay`** — only on the payment step, with an address on file; moves to
  `done`. This is the action the two "break it" bugs below get wrong.
- **`StartOver`** — only from `done`; resets both variables so the wizard can
  run again.

## 4. Observing the page

Notary reads the LiveView's rendered HTML directly — the same markup a
browser would see — instead of asking the template to expose a parallel,
test-only data format. `Notary.Conformance.LiveView` gives `project/1` a
small set of page-query helpers:

| Helper | Returns | Selector rule |
|---|---|---|
| `text(ctx, sel)` | trimmed text, internal whitespace runs (including non-breaking spaces) collapsed to one space | exactly 1 match |
| `texts(ctx, sel)` | list of texts (same normalisation), document order | 0+ |
| `has?(ctx, sel)` | boolean (any match) | — |
| `count(ctx, sel)` | number of matches | — |
| `attr(ctx, sel, name)` | attribute value, or `nil` if absent (a boolean attribute like `disabled` gives `""`) | exactly 1 |
| `value(ctx, sel)` | current value of an `<input>` (its `value` attribute), a `<textarea>` (raw text, not whitespace-collapsed), or a `<select>` (the selected option's value, falling back to its text if it has none, or the first option's if none is selected) | exactly 1 |
| `assigns(ctx)` | the LiveView's socket assigns map (escape hatch, below) | — |

`text/2` and `texts/2` read text the way a page visibly shows it, not raw
markup: `<script>` and `<style>` content is excluded (it's code, not
content), while a `hidden` element's text is still included (`hidden` doesn't
remove it from the DOM, just from what a user sees). Adjacent elements and
`<br>` add no separator between their text — the same "all the text, run
together" behavior as the DOM's `textContent`.

For the wizard, `step` and `address` are read straight from the elements a
user actually sees — the `<h2 id="step-title">` and the conditional
`<p id="address-summary">` in `MyAppWeb.WizardLive`'s template (section 5):

```elixir
def project(ctx) do
  %{"step" => ctx |> text("#step-title") |> String.downcase(),
    "address" => has?(ctx, "#address-summary")}
end
```

- **Reading the page checks the UI itself.** There's no parallel channel
  (a hidden marker) that could drift from what's actually rendered — go stale,
  or never get wired to the real state — because `project/1` sees exactly what
  the browser would. A missing or wrong `id`/selector fails the same way a
  missing button does: visibly, in the page.
- **An exactly-one helper that matches 0 or more than 1 element throws
  `:invalid_projection`** for the runner, same diagnostic path as any other
  projection bug: the message names the helper, selector, and match count,
  e.g. `text(ctx, "#step-title") matched 0 elements; it needs exactly one`.
- **`assigns(ctx)` is the escape hatch** for a fact the page never renders
  anywhere. It reads the LiveView's socket assigns directly, through
  LiveViewTest internals (see "Limits" below), so it depends on things that
  aren't part of any public contract. Reach for it only when there's truly
  nothing in the DOM to query.

## 5. The mapping

`MyAppWeb.WizardLive`, with a step title and a conditional summary (the
elements `project/1` reads above) and one element per action:

```elixir
defmodule MyAppWeb.WizardLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, step: "address", address: false)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <h2 id="step-title">{String.capitalize(@step)}</h2>
      <p :if={@address} id="address-summary">Shipping to 1 Main St</p>

      <form :if={@step == "address"} id="address-form" phx-submit="enter_address">
        <input name="address" value="" />
        <button type="submit">Save address</button>
      </form>
      <button :if={@step == "address"} id="continue" phx-click="continue" disabled={not @address}>
        Continue
      </button>
      <button :if={@step == "payment"} id="back" phx-click="back">Back</button>
      <button :if={@step == "payment"} id="pay" phx-click="pay">Pay</button>
      <button :if={@step == "done"} id="start-over" phx-click="start_over">Start over</button>
    </div>
    """
  end

  def handle_event("enter_address", %{"address" => _address}, socket),
    do: {:noreply, assign(socket, address: true)}

  def handle_event("continue", _, socket), do: {:noreply, assign(socket, step: "payment")}
  def handle_event("back", _, socket), do: {:noreply, assign(socket, step: "address")}
  def handle_event("pay", _, socket), do: {:noreply, assign(socket, step: "done")}

  def handle_event("start_over", _, socket),
    do: {:noreply, assign(socket, step: "address", address: false)}
end
```

And `MyAppWeb.Specs.Wizard`, the mapping module:

```elixir
defmodule MyAppWeb.Specs.Wizard do
  use Notary.Conformance, spec: "specs/Wizard.tla"
  import Notary.Conformance.LiveView

  @impl true
  def init, do: mount(MyAppWeb.WizardLive, endpoint: MyAppWeb.Endpoint)

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
    %{"step" => ctx |> text("#step-title") |> String.downcase(),
      "address" => has?(ctx, "#address-summary")}
  end

  @impl true
  def teardown(ctx), do: unmount(ctx)
end
```

A few things worth calling out:

- **`mount(MyAppWeb.WizardLive, endpoint: MyAppWeb.Endpoint)` mounts the
  module directly**, in isolation — no router needed. To go through your
  actual router instead (useful if the view relies on plugs in its pipeline,
  or redirects to a different route), mount it by path:
  `mount("/wizard", endpoint: MyAppWeb.Endpoint)`. A path requires a router
  and follows any redirect the LiveView issues, swapping in the redirect's
  target as the current view (or, if the target isn't a LiveView, falling
  back to the raw HTML).
- **`click/2` and `submit/3` check availability first.** Each one looks for
  the selector in the current render and checks it isn't `disabled` (for
  `submit`, its submit button too) before sending anything. If the element
  is missing or disabled, nothing is sent and the helper returns
  `{:rejected, {:not_available, selector}, ctx}` — the reason the runner
  recognizes for the `action_not_offered` rule in §1.
- **`text/2` and `has?/2` (like every helper here) render the current view**
  (or use the stored HTML, after a redirect to a non-LiveView page) and query
  it with the given CSS selector — see "Observing the page" above.
- **`teardown(ctx), do: unmount(ctx)` matters.** `mount/2` can be called
  outside an ExUnit test process (conformance runs happen in their own
  process, and `mix notary.verify` doesn't start ExUnit at all), so it
  registers the calling process with ExUnit itself when needed. `unmount/1`
  cleans that up, and is safe to call more than once. Without it, the
  runner still stops the run's linked processes (the test supervisor and the
  LiveView with it), but the registration's row in ExUnit's internal table
  stays for the life of the VM. `teardown/1` is skipped on some failure
  paths, so a few such rows can remain anyway: a small, bounded leak.
- **Async work is settled automatically.** After every `click`/`submit`/
  `change`, and again whenever a view is installed (the first `mount`, or the
  target of a redirect), the helpers call `render_async/2` so that
  `assign_async`/`start_async` results land before `project/1` runs. You
  don't need to do anything for this yourself — just be aware it's there (see
  "Limits" below for what it doesn't cover).

## 6. Running it

```console
$ mix notary.check Wizard
Wizard: pass
  check: pass (4 distinct states)

Notary: all checks passed.
```

Four states: `step = "address"` with `address` either `FALSE` or `TRUE`, then
`step = "payment"` and `step = "done"` (both only reachable with `address =
TRUE`, since `Continue` requires it and nothing ever clears it before
`StartOver`). That's 4 of the 6 combinations `TypeOK` allows —
`step = "payment"`/`"done"` with `address = FALSE` are never reached.

```console
$ mix notary.test Wizard --seed 1
Wizard: pass
  check: pass (4 distinct states)
  conformance: pass (100 runs, seed 1)
    coverage: actions 5/5, observed states 4/4, transitions 6/6

Notary: all checks passed.
```

All five actions, all four states, all six transitions in the graph — driven
through the real LiveView via `click`/`submit`, projected back by reading the
rendered page with `text/2` and `has?/2`.

## 7. Break it

Two ways to get `Pay` wrong, both real bugs the availability rule exists for.

**Bug 1: `Pay` shown (and wired up) one step early.** Suppose the "Pay"
button's `:if` is written `@step in ["address", "payment"]` instead of
`@step == "payment"`. The button now appears — and works — before the
address step is even done. `EnterAddress`, `Continue`, `Back`, `StartOver`
are untouched; only `Pay`'s guard in the template is wrong.

```console
$ mix notary.test Wizard --seed 1
Wizard: FAIL
  check: pass (4 distinct states)
  conformance: fail
    error[action_not_enabled]: Pay was accepted, but the spec doesn't allow it in address = FALSE, step = "address"
       ╭─[specs/Wizard.tla:27:11]
       │
    25 │         /\ UNCHANGED address
    26 │ 
    27 │ Pay == /\ step = "payment"
       •           ───────┬────────
       •                  ╰── one of these is false in address = FALSE, step = "address"
    28 │        /\ address
       •           ───┬───
       •              ╰── one of these is false in address = FALSE, step = "address"
    29 │        /\ step' = "done"
    30 │        /\ UNCHANGED address
       │
       ╰─────
         help: return {:rejected, reason, ctx}
    
    Conformance failure in Wizard: action_not_enabled (seed 1)
    The implementation accepted an action the spec does not allow in this state. It should have returned {:rejected, reason, ctx}.
    
      step  action / params / outcome / implementation state
      0     (init)   ok          address = FALSE, step = "address"
      1     Pay %{}  ok          address = FALSE, step = "done"   <-- diverges here
    
    Spec allowed: (no Pay transition is enabled here)
    minimized: 3 replays, 1 items removed, 0 params reduced
    
    Reproduce: mix notary.test Wizard --seed 1
    Visualize: mix notary.graph Wizard --trace failure --open

Notary: verification FAILED.
```

This is the ordinary `action_not_enabled` failure: the element was present
and enabled, `click/2` sent the event, and the implementation moved to a
state the spec doesn't allow from there. Nothing LiveView-specific about the
verdict — it's exactly what a non-UI mapping would get for accepting an
action too early. Measured over seeds 1..10 at the default 100 runs, this bug
is caught on 10/10 seeds.

**Bug 2: `Pay` never shown.** Suppose the button's `:if` is dropped
entirely, or hardcoded to `false` — "Pay" just never renders, on any step.

```console
$ mix notary.test Wizard --seed 1
Wizard: FAIL
  check: pass (4 distinct states)
  conformance: fail
    error[action_not_offered]: Pay was not offered, but the spec allows it in address = TRUE, step = "payment"
       ╭─[specs/Wizard.tla:27:11]
       │
    25 │         /\ UNCHANGED address
    26 │ 
    27 │ Pay == /\ step = "payment"
       •           ───────┬────────
       •                  ╰── true here: address = TRUE, step = "payment"
    28 │        /\ address
       •           ───┬───
       •              ╰── true here: address = TRUE, step = "payment"
    29 │        /\ step' = "done"
    30 │        /\ UNCHANGED address
       │
       ╰─────
         help: the UI must offer Pay here; "#pay" was missing or disabled
    
    Conformance failure in Wizard: action_not_offered (seed 1)
    The spec allows this action here, but the UI did not offer it (the element was missing or disabled).
    
      step  action / params / outcome / implementation state
      0     (init)            ok          address = FALSE, step = "address"
      1     EnterAddress %{}  ok          address = TRUE, step = "address"
      2     Continue %{}      ok          address = TRUE, step = "payment"
      3     Pay %{}           rejected {:not_available, "#pay"}  address = TRUE, step = "payment"   <-- diverges here
    
    Spec allowed: address = TRUE, step = "payment"
    minimized: 3 replays, 0 items removed, 0 params reduced
    selector: #pay
    
    Reproduce: mix notary.test Wizard --seed 1
    Visualize: mix notary.graph Wizard --trace failure --open

Notary: verification FAILED.
```

This is the new rule: `click(ctx, "#pay")` correctly reported
`{:rejected, {:not_available, "#pay"}, ctx}` (the mapping didn't lie), but
every state consistent with what's been observed so far enables `Pay`, so the
UI should have offered it and didn't. The diagnostic underlines the same
guard conjuncts as Bug 1 — this time because they're *true*, which is why the
action is expected — and `help:` and `--json`'s `"selector"` both name the
missing element. Measured the same way, this bug is caught on 10/10 seeds.

## 8. Limits

- **One view, one actor.** Phase 2a drives a single LiveView from a single
  simulated user. Multiple views, multiple actors, and PubSub-driven updates
  from other processes are Phase 2b.
- **`render_async/2` only settles the top-level view.** If `WizardLive`
  mounted a child LiveView with its own `assign_async`/`start_async` work,
  that child's async results are not guaranteed to have landed before
  `project/1` runs — only the view you directly `mount`ed (or redirected
  into) is settled.
- **No JS hooks.** `phx-hook` client-side behavior and `JS.*` commands are
  never exercised; `click`/`submit`/`change` only ever send the server
  events LiveView itself would send for a real click/submit/change.
- **`assigns/1` depends on LiveView internals** (it reads the channel
  process's socket assigns via `:sys.get_state/1`), and is documented as
  unstable for exactly that reason. Prefer the DOM helpers in "Observing the
  page" above; reach for `assigns/1` only when a fact truly can't be rendered.
- **The helpers rely on internals of LiveViewTest and ExUnit.** They call
  undocumented `Phoenix.LiveViewTest` functions (`__live__/3`,
  `__isolated__/4`, `__follow_redirect__/4`) to mount and follow redirects
  outside of ExUnit's own test lifecycle, and they register the run's process
  with ExUnit's internal OnExitHandler table so LiveViewTest accepts it as
  a test process. None of these are part of a public contract.
- **The availability check is simple.** It looks at the matched element's
  own `disabled` attribute and, for `submit/3`, at the submit buttons inside
  the form. It does not consider a submit button outside the form
  (`form="id"`), `input[type=image]`, or `fieldset[disabled]`.
- **`value/2` on a `<select multiple>` returns only the first selected
  option** (in DOM order), not the full selection. Multi-select forms are
  rare in LiveView; if you have one, read the options with `attr/3`/`texts/2`
  instead.

## Next steps

- [Rate Limiter: Constants and Time](rate-limiter.md) covers constants and
  modeling time as an external action — ideas that apply to LiveView mappings
  just as much as function-level ones.
- See the README's "LiveView" section for the measured catch rates above, and
  `Notary.Conformance.LiveView` for the full function reference.
