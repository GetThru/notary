# Outlaw: pentiment source diagnostics

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Text reports show compiler-style diagnostics that point into the spec's `.tla` and the mapping module's source, and JSON reports carry a `location`.

**Architecture:** Two pure locators find source positions (`Outlaw.Spec.Locate` for `.tla`, `Outlaw.Mapping.Locate` for mapping modules). `Outlaw.Diagnostic` turns a `Failure` or `Outlaw.Error` plus context (spec, mapping module) into a `Pentiment.Report` and its sources. `Outlaw.Report` renders it with `Pentiment.format/3` ahead of the existing step table, falling back to today's text when nothing is located.

**Tech Stack:** Elixir 1.19 / OTP 27, pentiment ~> 0.2 (no runtime deps).

**Spec:** `docs/superpowers/specs/2026-09-30-outlaw-design.md` §9.1 (binding — the table there says what each kind points at).

## Global Constraints

- Branch: create `pentiment-diagnostics` from `main` first. Commands as `nix develop -c <cmd>`; TLC tests need `--include tlc`.
- `specs/` and `specs/.outlaw.lock` are locked — never edit them.
- Text output: when no location is found, the report is exactly today's text. JSON keeps its current shape; only an added `"location": {"file", "line", "column"}` key on failures/errors that have one.
- Tests render with colors off. Colors on only when stdout is a TTY, `IO.ANSI.enabled?/0` is true and `--json` is not set.
- Never claim which guard conjunct is false when there are several (Outlaw doesn't evaluate TLA+).
- `mix format --check-formatted`, `mix compile --warnings-as-errors` (dev and `MIX_ENV=test`) clean; test output pristine. Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. TDD with a real failing run.

## Existing interfaces (HEAD 08bc660 on main)

- `Outlaw.Report.format/1` (report map `%{status, lock, specs: [%{spec, status, stages: [%{stage, status, payload, ...extra}]}]}`), `format_failure/2`, `format_violation/2`, `format_state/1`, `to_json/1`; private `format_stage/2`, `failure_json/1`, `error_json/1`.
- `Outlaw.Verify` builds stages (`stage/4` with an `extra` map; conformance stages carry `internal:`, `fair:`); `test_spec/3`, `check_spec/2`.
- `Outlaw.Conformance.assert_conforms/2` raises `Outlaw.Error` whose message is `Report.format/1` text.
- `%Outlaw.Conformance.Failure{kind, seed, steps, details}`; `details` may contain `:during` (e.g. `"action/3 Inc %{}"`, `"project/1"`, `"init/0"`, `"settle"`), `:exception` (formatted string), `:pending`, `:got`, `:expected`, `:variable`, `:value`, `:minimized`.
- Runner rescue: `lib/outlaw/conformance/runner.ex` `e -> {:fail, :exception, %{exception: Exception.format(:error, e, __STACKTRACE__)}}`.
- `%Outlaw.Error{kind: :spec_error, details: %{location: %{module, line, column} | nil, output}}` from `Outlaw.TLC.Output`; `:invalid_mapping` from `Outlaw.Conformance.validate/2`.
- `Outlaw.Spec{name, dir, tla_path, cfg_path}`; `Outlaw.Conformance.spec(module)`.

---

### Task 1: Locators and the pentiment dependency

**Files:** Modify `mix.exs` (add `{:pentiment, "~> 0.2"}`); create `lib/outlaw/spec/locate.ex`, `lib/outlaw/mapping/locate.ex`, `test/outlaw/spec/locate_test.exs`, `test/outlaw/mapping/locate_test.exs`.

**Interfaces (produce):**
- `Outlaw.Spec.Locate.definition(tla_text, name) :: %{name, line, column, end_line, conjuncts: [%{kind: :guard | :effect, line, column, end_line, end_column, text}]} | nil` — finds `Name ==` or `Name(params) ==` at line start (after optional whitespace), ignoring matches inside `\*` line comments and `(* *)` block comments; body runs until the next top-level definition, a `====` line, or a `----` separator. Conjuncts: when the body (first token after `==`, possibly on the next line) is a `/\` list, each `/\` item at the list's indentation becomes a conjunct spanning to just before the next sibling `/\` (multi-line conjuncts allowed); `:effect` if its text contains an identifier immediately followed by `'` (primed variable), else `:guard`. Body not a `/\` list → `conjuncts: []`.
- `Outlaw.Spec.Locate.fairness(tla_text, action_name) :: %{line, column, end_column, text} | nil` — the `WF_…(Name…)` / `SF_…(Name…)` occurrence (same comment stripping as `Outlaw.Spec.fair_actions/1`; keep one comment-stripping implementation and reuse it).
- `Outlaw.Mapping.Locate.locate(module) :: %{file, use_line, init_line, actions_line, project_line, action_lines: %{String.t() => pos_integer()}} | nil` — `file` from `module.module_info(:compile)[:source]` (convert charlist; `nil` if missing/unreadable); parse with `Code.string_to_quoted(source, columns: true)`; find the `defmodule` for `module`, then inside it the `use Outlaw.Conformance` call and the `def init/0`, `def actions/0`, `def project/1` and `def action/3` clauses (for `action/3`, the first clause whose first argument is a string literal records that string; a catch-all clause records `"*"`). Missing pieces are `nil`.

**Tests:**
- Spec: on `test/fixtures/specs/Counter.tla` `Inc` → guard `x < Max`, effect `x' = x + 1`; `Reset` (single-line, no `/\`) → `conjuncts: []`; Bank `Withdraw(a)` (parameterized) → guard `a <= balance`, 2 effects; Workflow `Pay(u)` with an `EXCEPT` effect; specs/TLCRunner.tla `Exit` (multi-line conjunct with `IF`) and `fairness(_, "Reap")`; a definition name appearing only in a comment is not found; unknown name → `nil`.
- Mapping: `Outlaw.Fixtures.CounterSpec` (multi-clause `action/3`: `"Inc"`, `"Reset"`), `Outlaw.Fixtures.BankOverdraftSpec` (delegated callbacks → `nil` lines, not a crash), a module without source → `nil`.

- [ ] RED, implement, GREEN, commit.

---

### Task 2: Conformance failure diagnostics

**Files:** Create `lib/outlaw/diagnostic.ex`, `test/outlaw/diagnostic_test.exs`; modify `lib/outlaw/report.ex`, `lib/outlaw/verify.ex`, `lib/outlaw/conformance/runner.ex` (keep the raw top in-project stack frame `{file, line}` in `details.frame` for `:exception`), `lib/outlaw/conformance.ex` (`assert_conforms` passes the context), tests in `test/outlaw/report_test.exs`.

**Interfaces:**
- `Outlaw.Diagnostic.failure(failure, spec: Spec.t(), mapping: module() | nil) :: {Pentiment.Report.t(), sources :: map()} | nil` implementing every `Failure` row of §9.1's table; `nil` when nothing can be located.
- `Outlaw.Diagnostic.render(diagnostic_or_nil, colors: boolean()) :: String.t() | nil`.
- Verify attaches `spec: spec` and `mapping: module | nil` to conformance and check stages' extra map; `Report.format/1` and `format_failure/2,3` use them (`format_failure(spec_name, failure, context \\ [])`).
- `Report.format/2` takes `colors: boolean()` (default `false`).

**Rendering:** diagnostic first, then the existing failure text (explanation, step table, Spec allowed, details, Reproduce/Visualize) unchanged. Error code = the failure kind (e.g. `error[action_not_enabled]`). Use `Outlaw.Report.format_state/1` for ⟨state⟩ text.

**Tests (colors off, exact substrings):** CounterNoGuardSpec → `action_not_enabled` points at `Counter.tla`'s `x < Max` line with "false here: x = 3"; CounterBadResetSpec → `illegal_transition`: `Reset` has no `/\` list → falls back to the `Reset ==` line with "implementation reached x = 1"; CounterSideEffectSpec → `rejected_with_side_effect` at `Inc ==`; CounterBadInitSpec → `Init`; AsyncStalledSpec → `internal_action_stalled` at `Complete` plus the `WF_status(Complete)` secondary; CounterBadProjectionSpec → `def project` in `test/support/fixtures/counter_specs.ex`; CounterRaisingSpec → `exception` at the raising line in that file; CounterSlowSpec → `timeout` at `def action("Inc", ...)`; a failure with no locatable source renders exactly the old text (assert equality with a captured old rendering).

- [ ] RED, implement, GREEN, full suite `--include tlc`, commit.

---

### Task 3: Error diagnostics, JSON locations, colors, guide

**Files:** modify `lib/outlaw/diagnostic.ex` (add `error/2`), `lib/outlaw/report.ex`, `lib/outlaw/cli.ex` (colors decision), `guides/getting-started.md`; tests.

**Interfaces:** `Outlaw.Diagnostic.error(%Outlaw.Error{}, spec: Spec.t() | nil, mapping: module() | nil) :: {report, sources} | nil` for `:invalid_mapping` (primary `use Outlaw.Conformance` line, secondary `def actions`, help from the error message) and `:spec_error` (primary at `details.location` in `<spec.dir>/<module>.tla`, message = the SANY error text's first meaningful line, note = the rest); `Outlaw.Diagnostic.location(failure_or_error, context) :: %{file, line, column} | nil` (file relative to cwd).

**JSON:** `failure_json` / `error_json` add `"location"` when `location/2` returns one.

**Colors:** `Outlaw.CLI.finish/2` renders text with `colors: IO.ANSI.enabled?() and tty?(:stdio)` (`:io.columns() != {:error, :enotsup}` or equivalent), never when `--json`; `assert_conforms` renders plain.

**Guide:** re-run `guides/getting-started.md` §5 (invalid-mapping verify output) and §7 (broken guard) for real in a scratch `hello_outlaw` project (path dep on this repo, as the guide describes) and paste the new outputs; explain the diagnostic in one or two sentences.

**Tests:** invalid_mapping diagnostic on `CounterUnknownActionSpec`; spec_error on `test/fixtures/specs_bad/Broken.tla` (`:tlc` tag) pointing at line 3; JSON `location` present for both a failure and an error, absent otherwise; `mix outlaw.verify` still passes.

- [ ] RED, implement, GREEN, full suite `--include tlc`, `mix docs` without warnings, commit.
