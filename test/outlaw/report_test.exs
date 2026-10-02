defmodule Outlaw.ReportTest do
  use ExUnit.Case, async: true

  alias Outlaw.{Error, Report, Value}
  alias Outlaw.Conformance.{Failure, Step}

  @failure %Failure{
    kind: :action_not_enabled,
    seed: 1234,
    steps: [
      %Step{index: 0, outcome: :ok, projection: %{"balance" => 0}, allowed: [%{"balance" => 0}]},
      %Step{
        index: 1,
        action: "Withdraw",
        params: %{a: 1},
        outcome: :ok,
        projection: %{"balance" => -1},
        allowed: []
      }
    ]
  }

  @violation %{
    kind: :invariant,
    name: "Small",
    message: "Invariant Small is violated.",
    trace: [
      %{index: 1, action: nil, state: %{"x" => 0}},
      %{index: 2, action: "Next", state: %{"x" => 1}}
    ]
  }

  defp report(stages, status \\ :fail),
    do: %{
      status: status,
      lock: %{stage: :lock, status: :pass, payload: :ok},
      specs: [%{spec: "Bank", status: status, stages: stages}]
    }

  test "format appends an Error's output_tail/raw details not already in the message" do
    timeout_error =
      Error.new(:tlc_timeout, "TLC did not finish within 1000ms and was stopped.", %{
        output_tail: "Progress(4): ...\nComputing initial states..."
      })

    text =
      report([%{stage: :check, status: :error, payload: {:error, timeout_error}}])
      |> Report.format()

    assert text =~ "TLC did not finish within 1000ms"
    assert text =~ "Progress(4): ..."
    assert text =~ "Computing initial states..."

    raw_error =
      Error.new(
        :unparseable_state,
        "Outlaw could not parse a TLC state. This is an Outlaw bug; please report it with the raw text.",
        %{raw: "weird \\* garbage"}
      )

    text2 =
      report([%{stage: :check, status: :error, payload: {:error, raw_error}}]) |> Report.format()

    assert text2 =~ "please report it with the raw text"
    assert text2 =~ "weird \\* garbage"
  end

  test "format does not duplicate an Error's :output detail already present in the message" do
    spec_error =
      Error.new(:spec_error, "TLA+ spec error in Counter.tla:3:1:\nboom, this exact text", %{
        output: "boom, this exact text"
      })

    text =
      report([%{stage: :check, status: :error, payload: {:error, spec_error}}]) |> Report.format()

    assert length(:binary.matches(text, "boom, this exact text")) == 1
  end

  test "format and to_json do not raise for mistyped projection values (nil/atom/tuple)" do
    failure = %Failure{
      kind: :invalid_projection,
      seed: 7,
      steps: [
        %Step{
          index: 0,
          outcome: :ok,
          projection: %{"status" => nil},
          allowed: [%{"status" => "open"}]
        },
        %Step{
          index: 1,
          action: "Go",
          params: %{},
          outcome: :ok,
          projection: %{"status" => :pending, "extra" => {:a, :b}},
          candidates: [],
          allowed: []
        }
      ],
      details: %{variable: "status", value: :pending, message: "bad value"}
    }

    report = %{
      status: :fail,
      lock: nil,
      specs: [
        %{
          spec: "Bank",
          status: :fail,
          stages: [%{stage: :conformance, status: :fail, payload: {:error, failure}}]
        }
      ]
    }

    text = Report.format(report)
    assert text =~ "status = nil"
    assert text =~ "status = :pending"
    assert text =~ "extra = {:a, :b}"

    json = Report.to_json(report)
    encoded = JSON.encode!(json)
    assert is_binary(encoded)
    assert %{"specs" => [_]} = JSON.decode!(encoded)
  end

  test "format_state uses TLA+ syntax" do
    assert Report.format_state(%{"b" => Value.set([1]), "a" => "x"}) == ~S(a = "x", b = {1})
  end

  test "format_failure explains, tabulates steps, marks divergence and gives next commands" do
    text = Report.format_failure("Bank", @failure)
    assert text =~ "Conformance failure in Bank: action_not_enabled (seed 1234)"
    assert text =~ "should have returned {:rejected, reason, ctx}"
    assert text =~ "(init)"
    assert text =~ "Withdraw %{a: 1}"
    assert text =~ "balance = -1"
    assert text =~ "<-- diverges here"
    assert text =~ "Spec allowed: (no Withdraw transition is enabled here)"
    assert text =~ "mix outlaw.test Bank --seed 1234"
    assert text =~ "mix outlaw.graph Bank --trace failure"
  end

  @old_failure_text """
  Conformance failure in Bank: action_not_enabled (seed 1234)
  The implementation accepted an action the spec does not allow in this state. It should have returned {:rejected, reason, ctx}.

    step  action / params / outcome / implementation state
    0     (init)            ok          balance = 0
    1     Withdraw %{a: 1}  ok          balance = -1   <-- diverges here

  Spec allowed: (no Withdraw transition is enabled here)

  Reproduce: mix outlaw.test Bank --seed 1234
  Visualize: mix outlaw.graph Bank --trace failure --open\
  """

  test "format_failure/2 (no context) renders exactly today's plain text -- captured before pentiment diagnostics existed" do
    assert Report.format_failure("Bank", @failure) == @old_failure_text
  end

  test "format_failure/3 with a context that can't locate a source renders exactly the same text" do
    unlocatable_spec = Outlaw.Spec.from_path("test/fixtures/specs/NoSuchSpec.tla")

    text = Report.format_failure("Bank", @failure, spec: unlocatable_spec, mapping: nil)

    assert text == @old_failure_text
  end

  test "format_failure renders a (settle) step without trailing params when params is nil" do
    failure = %Failure{
      kind: :internal_action_stalled,
      seed: 9,
      steps: [
        %Step{index: 0, outcome: :ok, projection: %{"status" => "idle"}, allowed: []},
        %Step{
          index: 1,
          action: "(settle)",
          params: nil,
          outcome: :ok,
          projection: %{"status" => "pending"},
          allowed: []
        }
      ],
      details: %{pending: ["Complete"], settle_timeout: 50}
    }

    text = Report.format_failure("Async", failure)
    assert text =~ "(settle)"
    refute text =~ "(settle) nil"
  end

  test "a failure's minimized detail renders in text and JSON" do
    failure = %{
      @failure
      | details: %{minimized: "6 replays, 4 items removed, 1 params reduced"}
    }

    text = Report.format_failure("Bank", failure)
    assert text =~ "\nminimized: 6 replays, 4 items removed, 1 params reduced\n"

    json =
      report([%{stage: :conformance, status: :fail, payload: {:error, failure}}])
      |> Report.to_json()
      |> JSON.encode!()
      |> JSON.decode!()

    [conf] = hd(json["specs"])["stages"]

    assert conf["failure"]["details"]["minimized"] ==
             "6 replays, 4 items removed, 1 params reduced"
  end

  test "an exception failure's raw :frame never leaks into JSON (it's Outlaw.Diagnostic's plumbing, not user-facing data)" do
    failure = %{
      @failure
      | kind: :exception,
        details: %{
          exception: "** (RuntimeError) boom",
          frame: {"test/support/fixtures/counter_specs.ex", 180}
        }
    }

    json =
      report([%{stage: :conformance, status: :fail, payload: {:error, failure}}])
      |> Report.to_json()
      |> JSON.encode!()
      |> JSON.decode!()

    [conf] = hd(json["specs"])["stages"]

    assert conf["failure"]["details"]["exception"] == "** (RuntimeError) boom"
    refute Map.has_key?(conf["failure"]["details"], "frame")
  end

  test "format_violation shows the counterexample" do
    text = Report.format_violation("Inv", @violation)
    assert text =~ "TLC found a violation in Inv: Invariant Small is violated. (invariant)"
    assert text =~ "1. (initial)  x = 0"
    assert text =~ "2. Next  x = 1"
  end

  test "a passing conformance stage shows declared internal actions and marks the fair ones" do
    text =
      report(
        [
          %{
            stage: :conformance,
            status: :pass,
            payload: {:ok, %{runs: 100, seed: 7}},
            internal: ["LimitKill", "Reap"],
            fair: ["Reap"]
          }
        ],
        :pass
      )
      |> Report.format()

    assert text =~ "conformance: pass (100 runs, seed 7; internal: LimitKill, Reap*; * = fair)"
  end

  test "a passing conformance stage with no internal actions shows no internal suffix" do
    text =
      report(
        [
          %{
            stage: :conformance,
            status: :pass,
            payload: {:ok, %{runs: 100, seed: 7}},
            internal: [],
            fair: []
          }
        ],
        :pass
      )
      |> Report.format()

    assert text =~ "conformance: pass (100 runs, seed 7)"
    refute text =~ "internal:"
  end

  @full_coverage %{
    actions: %{reached: 9, total: 9, unreached: []},
    states: %{reached: 29, total: 29, unreached: []},
    transitions: %{reached: 52, total: 57, unreached: [{%{"x" => 1}, "Inc", %{"x" => 2}}]}
  }

  @gappy_coverage %{
    actions: %{reached: 8, total: 9, unreached: ["LimitKill"]},
    states: %{reached: 27, total: 29, unreached: [%{"x" => 5}, %{"x" => 9}]},
    transitions: %{reached: 52, total: 57, unreached: [{%{"x" => 1}, "Inc", %{"x" => 2}}]}
  }

  test "a passing conformance stage shows the coverage line" do
    text =
      report(
        [
          %{
            stage: :conformance,
            status: :pass,
            payload: {:ok, %{runs: 100, seed: 7, coverage: @full_coverage}},
            internal: [],
            fair: []
          }
        ],
        :pass
      )
      |> Report.format()

    assert text =~ "conformance: pass (100 runs, seed 7)"
    assert text =~ "coverage: actions 9/9, observed states 29/29, transitions 52/57"
    refute text =~ "warning:"
  end

  test "coverage gaps add warning lines but the stage stays pass" do
    report_map =
      report(
        [
          %{
            stage: :conformance,
            status: :pass,
            payload: {:ok, %{runs: 100, seed: 7, coverage: @gappy_coverage}},
            internal: [],
            fair: []
          }
        ],
        :pass
      )

    text = Report.format(report_map)

    assert text =~ "coverage: actions 8/9, observed states 27/29, transitions 52/57"
    assert text =~ "warning: never reached: LimitKill"
    assert text =~ "warning: 2 observed states never reached (first: x = 5)"

    [spec] = report_map.specs
    [stage] = spec.stages
    assert stage.status == :pass
  end

  test "a passing conformance stage without a coverage key renders no coverage line" do
    text =
      report(
        [
          %{
            stage: :conformance,
            status: :pass,
            payload: {:ok, %{runs: 100, seed: 7}},
            internal: [],
            fair: []
          }
        ],
        :pass
      )
      |> Report.format()

    assert text =~ "conformance: pass (100 runs, seed 7)"
    refute text =~ "coverage:"
  end

  test "to_json renders coverage with TLA+ text state projections and from/action/to transitions" do
    json =
      report([
        %{
          stage: :conformance,
          status: :pass,
          payload: {:ok, %{runs: 100, seed: 7, coverage: @gappy_coverage}},
          internal: [],
          fair: []
        }
      ])
      |> Report.to_json()

    [stage] = hd(json["specs"])["stages"]
    coverage = stage["coverage"]

    assert coverage["actions"] == %{"reached" => 8, "total" => 9, "unreached" => ["LimitKill"]}
    assert coverage["states"]["unreached"] == [%{"x" => "5"}, %{"x" => "9"}]

    assert coverage["transitions"]["unreached"] == [
             %{"from" => %{"x" => "1"}, "action" => "Inc", "to" => %{"x" => "2"}}
           ]

    encoded = JSON.encode!(json)
    assert is_binary(encoded)
  end

  test "to_json omits coverage when the payload has none" do
    json =
      report([
        %{
          stage: :conformance,
          status: :pass,
          payload: {:ok, %{runs: 100, seed: 7}},
          internal: [],
          fair: []
        }
      ])
      |> Report.to_json()

    [stage] = hd(json["specs"])["stages"]
    refute Map.has_key?(stage, "coverage")
  end

  test "to_json includes internal/fair on the conformance stage" do
    json =
      report([
        %{
          stage: :conformance,
          status: :pass,
          payload: {:ok, %{runs: 100, seed: 7}},
          internal: ["LimitKill", "Reap"],
          fair: ["Reap"]
        }
      ])
      |> Report.to_json()

    [stage] = hd(json["specs"])["stages"]
    assert stage["internal"] == ["LimitKill", "Reap"]
    assert stage["fair"] == ["Reap"]
  end

  test "format summarises all stages" do
    text =
      report([
        %{
          stage: :check,
          status: :pass,
          payload: {:ok, %{distinct_states: 8, states_generated: 20}}
        },
        %{stage: :conformance, status: :fail, payload: {:error, @failure}}
      ])
      |> Report.format()

    assert text =~ "lock: pass"
    assert text =~ "Bank: FAIL"
    assert text =~ "check: pass (8 distinct states)"
    assert text =~ "conformance: fail"
    assert text =~ "<-- diverges here"
  end

  test "a conformance stage carrying spec/mapping context renders the diagnostic before the legacy text" do
    counter_spec = Outlaw.Spec.from_path("test/fixtures/specs/Counter.tla")

    {:error, failure} =
      Outlaw.Conformance.check(
        Outlaw.Fixtures.CounterNoGuardSpec,
        Outlaw.Fixtures.graph("Counter"),
        seed: 42,
        max_runs: 200
      )

    text =
      report([
        %{
          stage: :conformance,
          status: :fail,
          payload: {:error, failure},
          internal: [],
          fair: [],
          spec: counter_spec,
          mapping: Outlaw.Fixtures.CounterNoGuardSpec
        }
      ])
      |> Report.format()

    assert text =~ "error[action_not_enabled]"
    assert text =~ "Inc was accepted, but the spec doesn't allow it in x = 3"
    assert text =~ "test/fixtures/specs/Counter.tla:10:11"
    assert text =~ "Conformance failure in Bank: action_not_enabled"
  end

  test "a malformed Failure never breaks the report -- diagnostic building/rendering falls back to the legacy text" do
    counter_spec = Outlaw.Spec.from_path("test/fixtures/specs/Counter.tla")
    # No steps at all: every Diagnostic builder indexes into f.steps (List.last,
    # Enum.at(-2), ...), so this would raise inside Outlaw.Diagnostic were it
    # not guarded.
    malformed = %Failure{kind: :action_not_enabled, seed: 1, steps: []}

    text =
      Report.format_failure("Bank", malformed, spec: counter_spec, mapping: nil)

    assert text == Report.format_failure("Bank", malformed)
    refute text =~ "error["
  end

  test "to_json is encodable and structured for LLMs" do
    json =
      report([
        %{stage: :check, status: :fail, payload: {:violation, @violation}},
        %{stage: :conformance, status: :skipped, payload: :skipped}
      ])
      |> Report.to_json()

    encoded = JSON.encode!(json)

    assert %{"status" => "fail", "lock" => %{"status" => "pass"}, "specs" => [spec]} =
             JSON.decode!(encoded)

    assert [
             %{"stage" => "check", "violation" => v},
             %{"stage" => "conformance", "status" => "skipped"}
           ] = spec["stages"]

    assert v["kind"] == "invariant"
    assert [%{"index" => 1, "action" => nil, "state" => %{"x" => "0"}}, _] = v["trace"]
  end

  test "to_json renders failures and errors" do
    json =
      report([
        %{
          stage: :check,
          status: :pass,
          payload: {:ok, %{distinct_states: 8, states_generated: 20}}
        },
        %{stage: :conformance, status: :fail, payload: {:error, @failure}}
      ])
      |> Report.to_json()
      |> JSON.encode!()
      |> JSON.decode!()

    [_, conf] = hd(json["specs"])["stages"]
    f = conf["failure"]
    assert f["kind"] == "action_not_enabled"
    assert f["seed"] == 1234
    assert f["failed_step"] == 1
    assert f["explanation"] =~ "rejected"

    assert [
             %{"action" => nil},
             %{
               "action" => "Withdraw",
               "params" => "%{a: 1}",
               "state" => %{"balance" => "-1"},
               "spec_allowed" => []
             }
           ] = f["steps"]

    err =
      Report.to_json(
        report([
          %{
            stage: :check,
            status: :error,
            payload: {:error, Error.new(:spec_error, "bad", %{location: %{line: 3}})}
          }
        ])
      )

    assert %{
             "error" => %{
               "kind" => "spec_error",
               "message" => "bad",
               "details" => %{"location" => %{"line" => 3}}
             }
           } =
             err
             |> JSON.encode!()
             |> JSON.decode!()
             |> Map.fetch!("specs")
             |> hd()
             |> Map.fetch!("stages")
             |> hd()
  end
end
