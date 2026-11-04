defmodule ExPanda.Walker.Ctx do
  @moduledoc """
  Walker context threaded through `ExPanda.Walker`.

  Bundles the `Macro.Env` with the walker's own options so that option values
  (currently `:expand_operators`) travel alongside the environment without
  polluting `Macro.Env` (which has no user-defined fields).

  ## Fields

    * `:env` - the current `Macro.Env`
    * `:expand_operators` - when `true` (the default), operators are expanded
      like any other macro/special form (`1 + 2` -> `:erlang.+(1, 2)`).
      When `false`, operators are preserved and only their operands are
      expanded (`1 + 2` -> `1 + 2`).
  """

  @type t :: %__MODULE__{env: Macro.Env.t(), expand_operators: boolean()}

  defstruct env: nil, expand_operators: true

  @doc """
  Build a context from a `Macro.Env` and a keyword list of options.

  ## Examples

      iex> ctx = ExPanda.Walker.Ctx.new(ExPanda.EnvManager.new_env(), [])
      iex> ctx.expand_operators
      true

      iex> ctx = ExPanda.Walker.Ctx.new(ExPanda.EnvManager.new_env(), expand_operators: false)
      iex> ctx.expand_operators
      false
  """
  @spec new(Macro.Env.t(), keyword()) :: t()
  def new(%Macro.Env{} = env, opts \\ []) do
    %__MODULE__{env: env, expand_operators: Keyword.get(opts, :expand_operators, true)}
  end
end
