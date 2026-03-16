defmodule ExPanda.CompilerExpand do
  @moduledoc """
  Wrapper around `:elixir_expand.expand/3` for expression-level macro expansion.

  This module uses the Elixir compiler's internal expansion engine to produce
  fully expanded AST for expressions. It provides a version-guarded interface
  with a fallback to `Macro.expand/2` when the internal API is unavailable.

  The internal `:elixir_expand.expand/3` is more thorough than `Macro.expand/2`
  because it recursively expands all nested macros, resolves aliases, and handles
  special forms. However, it requires variables to be pre-registered in the
  environment and raises on undefined references.
  """

  @doc """
  Expand an expression AST using the compiler's internal expansion engine.

  Returns `{:ok, expanded_ast, updated_env}` on success, or
  `{:error, reason}` on failure.

  ## Parameters

    * `ast` - The Elixir AST to expand
    * `env` - A `Macro.Env` struct with the current compilation context

  ## Examples

      iex> env = ExPanda.EnvManager.new_env()
      iex> {:ok, expanded, _env} = ExPanda.CompilerExpand.expand({:unless, [line: 1], [true, [do: :never]]}, env)
      iex> match?({:case, _, _}, expanded)
      true
  """
  @spec expand(Macro.t(), Macro.Env.t()) ::
          {:ok, Macro.t(), Macro.Env.t()} | {:error, String.t()}
  def expand(ast, env) do
    expand_via_compiler(ast, env)
  rescue
    e ->
      fallback_expand(ast, env, Exception.message(e))
  catch
    kind, reason ->
      message = "#{kind}: #{inspect(reason)}"
      fallback_expand(ast, env, message)
  end

  @doc """
  Check whether `:elixir_expand.expand/3` is available in the current runtime.
  """
  @spec compiler_available?() :: boolean()
  def compiler_available? do
    case :code.which(:elixir_expand) do
      :non_existing -> false
      _path -> function_exported?(:elixir_expand, :expand, 3)
    end
  end

  # --- Private ---

  defp expand_via_compiler(ast, env) do
    ex_env = :elixir_env.env_to_ex(env)
    {expanded, _ex_env, new_e_env} = :elixir_expand.expand(ast, ex_env, env)
    {:ok, expanded, new_e_env}
  end

  defp fallback_expand(ast, env, _compiler_error) do
    expanded = recursive_macro_expand(ast, env)
    {:ok, expanded, env}
  rescue
    e -> {:error, "Expansion failed: #{Exception.message(e)}"}
  end

  # Recursively apply Macro.expand via prewalk until fixpoint.
  defp recursive_macro_expand(ast, env) do
    Macro.prewalk(ast, fn node ->
      expand_until_fixpoint(node, env, 0)
    end)
  end

  @max_expansion_depth 100

  defp expand_until_fixpoint(node, _env, depth) when depth >= @max_expansion_depth, do: node

  defp expand_until_fixpoint(node, env, depth) do
    expanded = Macro.expand_once(node, env)

    if expanded == node do
      node
    else
      expand_until_fixpoint(expanded, env, depth + 1)
    end
  end
end
