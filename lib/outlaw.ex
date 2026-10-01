defmodule Outlaw do
  @moduledoc """
  Outlaw uses human-written TLA+ specifications as the contract between a
  developer and an LLM: TLC model-checks the spec, the LLM implements it, and
  Outlaw verifies the implementation conforms to the spec's state graph.

  Any behavior not in the spec is outlawed. Start with `mix outlaw.new`.
  """
end
