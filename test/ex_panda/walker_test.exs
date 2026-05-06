defmodule ExPanda.WalkerTest do
  use ExUnit.Case, async: true

  alias ExPanda.{EnvManager, Walker}

  describe "structural preservation" do
    test "preserves defmodule wrapper" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do :ok end")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:defmodule, _, [{:__aliases__, _, [:Foo]}, [do: :ok]]} = expanded
    end

    test "preserves def wrapper" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do def bar, do: :ok end")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:defmodule, _, [_, [do: {:def, _, [{:bar, _, _}, [do: :ok]]}]]} = expanded
    end

    test "preserves defp wrapper" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do defp bar, do: :ok end")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:defmodule, _, [_, [do: {:defp, _, [{:bar, _, _}, [do: :ok]]}]]} = expanded
    end

    test "preserves defmacro wrapper" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do defmacro bar, do: :ok end")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:defmodule, _, [_, [do: {:defmacro, _, [{:bar, _, _}, [do: :ok]]}]]} = expanded
    end
  end

  describe "expression expansion" do
    test "expands unless to case" do
      {:ok, ast} = Code.string_to_quoted("unless true, do: :never")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:case, _, [true, [do: _]]} = expanded
    end

    test "expands pipe to function call" do
      {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {{:., _, [String.Chars, :to_string]}, _, [1]} = expanded
    end
  end

  describe "block env threading" do
    test "threads env through block statements" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          require Logger
          def bar, do: :ok
        end
        """)

      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:defmodule, _, [_, [do: {:__block__, _, _stmts}]]} = expanded
    end
  end

  describe "mark_unexpanded/2" do
    test "wraps node with @unexpanded marker" do
      node = {:some_macro, [], [:arg]}
      result = Walker.mark_unexpanded(node, "test error")
      assert {:__block__, [], [marker, ^node]} = result
      assert {:@, [], [{:unexpanded, [], [description]}]} = marker
      assert description =~ "test error"
    end
  end

  describe "non-macro calls (no infinite loop)" do
    test "does not loop on remote function calls" do
      {:ok, ast} = Code.string_to_quoted("Enum.map([1, 2, 3], &to_string/1)")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {{:., _, _}, _, _} = expanded
    end

    test "does not loop on Task.async_stream" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def bar(enum) do
            Task.async_stream(enum, fn x -> x * 2 end)
          end
        end
        """)

      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:defmodule, _, _} = expanded
    end

    test "does not loop on local function calls" do
      {:ok, ast} = Code.string_to_quoted("to_string(42)")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      # to_string is a Kernel macro that delegates to String.Chars.to_string
      assert {{:., _, [String.Chars, :to_string]}, _, [42]} = expanded
    end
  end

  describe "match operator" do
    test "registers variables from pattern matching" do
      {:ok, ast} =
        Code.string_to_quoted("""
        defmodule Foo do
          def bar do
            x = 1
            unless x, do: :fallback
          end
        end
        """)

      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {:defmodule, _, [_, [do: def_node]]} = expanded
      assert {:def, _, [{:bar, _, _}, [do: {:__block__, _, _stmts}]]} = def_node
    end
  end
end
