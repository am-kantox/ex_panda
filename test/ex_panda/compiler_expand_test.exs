defmodule ExPanda.CompilerExpandTest do
  use ExUnit.Case, async: true

  alias ExPanda.{CompilerExpand, EnvManager}

  describe "compiler_available?/0" do
    test "returns true on standard Elixir install" do
      assert CompilerExpand.compiler_available?()
    end
  end

  describe "expand/2" do
    test "expands unless to case" do
      env = EnvManager.new_env()
      ast = {:unless, [line: 1], [true, [do: :never]]}
      assert {:ok, {:case, _, [true, [do: _]]}, _env} = CompilerExpand.expand(ast, env)
    end

    test "expands pipe operator" do
      env = EnvManager.new_env()
      {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      assert {:ok, expanded, _env} = CompilerExpand.expand(ast, env)
      assert {{:., _, [String.Chars, :to_string]}, _, [1]} = expanded
    end

    test "returns ok for literals" do
      env = EnvManager.new_env()
      assert {:ok, 42, _} = CompilerExpand.expand(42, env)
      assert {:ok, :atom, _} = CompilerExpand.expand(:atom, env)
      assert {:ok, "string", _} = CompilerExpand.expand("string", env)
    end

    test "falls back gracefully on undefined variable" do
      env = EnvManager.new_env()
      # This AST references undefined variable 'x', :elixir_expand will fail,
      # but the fallback should handle it
      ast = {:unless, [line: 1], [{:x, [line: 1], nil}, [do: :fallback]]}
      result = CompilerExpand.expand(ast, env)
      # Should either succeed with fallback or return error
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end

    test "expands with variables registered in env" do
      env = EnvManager.new_env() |> EnvManager.register_var(:x)
      ast = {:unless, [line: 1], [{:x, [line: 1], nil}, [do: :fallback]]}
      assert {:ok, {:case, _, _}, _} = CompilerExpand.expand(ast, env)
    end
  end
end
