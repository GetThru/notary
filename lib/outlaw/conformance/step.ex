defmodule Outlaw.Conformance.Step do
  @moduledoc """
  One step of a conformance run. Index 0 is the initial state (`action: nil`).
  `candidates` are the spec states consistent with the implementation after this
  step; `allowed` are the observed projections the spec permitted here.
  """
  defstruct [:index, :action, :params, :outcome, :projection, candidates: [], allowed: []]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          action: String.t() | nil,
          params: map() | nil,
          outcome: :ok | {:rejected, term()},
          projection: map(),
          candidates: [String.t()],
          allowed: [map()]
        }
end
