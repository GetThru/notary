defmodule Notary do
  @moduledoc """
  Notary uses human-written TLA+ specifications as the contract between a
  developer and an LLM: TLC model-checks the spec, the LLM implements it, and
  Notary verifies the implementation conforms to the spec's state graph.

  Any behavior not in the spec is uncertified. Start with `mix notary.new`.
  """
end
