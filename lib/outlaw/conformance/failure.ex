defmodule Outlaw.Conformance.Failure do
  @moduledoc "A conformance failure: what went wrong and the (shrunk) steps leading to it."

  alias Outlaw.Conformance.Step

  defstruct [:kind, :seed, steps: [], details: %{}]

  @type kind ::
          :init_mismatch
          | :illegal_transition
          | :action_not_enabled
          | :rejected_with_side_effect
          | :invalid_projection
          | :invalid_action_result
          | :exception
          | :timeout
          | :crashed

  @type t :: %__MODULE__{kind: kind(), seed: integer() | nil, steps: [Step.t()], details: map()}

  @explanations %{
    init_mismatch:
      "The implementation's initial state does not match any initial state of the spec.",
    illegal_transition:
      "The implementation's new state is not one the spec allows after this action.",
    action_not_enabled:
      "The implementation accepted an action the spec does not allow in this state. It should have returned {:rejected, reason, ctx}.",
    rejected_with_side_effect:
      "The implementation rejected the action, but its observable state changed.",
    invalid_projection: "project/1 must return exactly the observed spec variables.",
    invalid_action_result: "action/3 must return {:ok, ctx} or {:rejected, reason, ctx}.",
    exception: "The mapping module or the implementation raised an exception.",
    timeout: "A callback did not return within the action timeout.",
    crashed: "The process running the implementation crashed."
  }

  @spec new(kind(), [Step.t()], map()) :: t()
  def new(kind, steps, details), do: %__MODULE__{kind: kind, steps: steps, details: details}

  @spec kinds() :: [kind()]
  def kinds, do: Map.keys(@explanations)

  @spec explanation(kind()) :: String.t()
  def explanation(kind), do: Map.fetch!(@explanations, kind)
end
