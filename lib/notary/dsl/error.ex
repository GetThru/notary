defmodule Notary.DSL.Error do
  @moduledoc """
  A DSL compilation failure: an expression the DSL cannot translate, an
  invalid declaration, or a structural problem (no actions, an initial state
  that doesn't assign every variable).

  Raise sites pass either explicit `file:`/`line:` fields or a `meta:` keyword
  list (the `[file:, line:]` pairs threaded through translation). `message/1`
  prefixes the location when known, so the mix task can print
  `test/support/specs/checkout.ex:23: ...`.
  """

  defexception [:message, :file, :line, :meta]

  @type t :: %__MODULE__{
          message: String.t() | nil,
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          meta: keyword() | nil
        }

  @spec new(String.t(), keyword() | Macro.t()) :: t()
  def new(message, meta \\ [])

  def new(message, meta) when is_list(meta) do
    %__MODULE__{
      message: String.trim(message),
      file: meta[:file],
      line: meta[:line],
      meta: nil
    }
  end

  # A Macro.Env passed straight through: take file/line from it.
  def new(message, %Macro.Env{} = env) do
    %__MODULE__{
      message: String.trim(message),
      file: env.file,
      line: env.line,
      meta: nil
    }
  end

  @impl true
  def message(%__MODULE__{} = error) do
    meta = error.meta

    meta =
      cond do
        meta == nil -> []
        is_list(meta) -> meta
        is_struct(meta, Macro.Env) -> [file: meta.file, line: meta.line]
        true -> []
      end

    file = error.file || meta[:file]
    line = error.line || meta[:line]

    location =
      cond do
        file == nil -> ""
        line == nil -> "#{file}: "
        true -> "#{file}:#{line}: "
      end

    location <> (error.message || "")
  end
end
