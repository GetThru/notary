defmodule Notary.Error do
  @moduledoc "A structured, actionable Notary error. Also usable as an exception."
  defexception [:kind, :message, details: %{}]

  @type t :: %__MODULE__{kind: atom(), message: String.t(), details: map()}

  @spec new(atom(), String.t(), map()) :: t()
  def new(kind, message, details \\ %{}) when is_atom(kind) and is_binary(message) do
    %__MODULE__{kind: kind, message: message, details: details}
  end
end
