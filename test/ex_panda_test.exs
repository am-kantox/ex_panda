defmodule ExPandaTest do
  use ExUnit.Case, async: true

  describe "expand_string/2" do
    test "expands unless to case" do
      {:ok, expanded} = ExPanda.expand_string("unless true, do: :never")
      assert {:case, _, [true, [do: _clauses]]} = expanded
    end

    test "expands pipe operator" do
      {:ok, expanded} = ExPanda.expand_string("1 |> to_string()")
      assert {{:., _, [String.Chars, :to_string]}, _, [1]} = expanded
    end

    test "expands nested pipe chain" do
      {:ok, expanded} = ExPanda.expand_string("1 |> to_string() |> String.upcase()")

      assert {{:., _, [String, :upcase]}, _, [{{:., _, [String.Chars, :to_string]}, _, [1]}]} =
               expanded
    end

    test "returns error on parse failure" do
      assert {:error, msg} = ExPanda.expand_string("def )")
      assert is_binary(msg)
      assert msg =~ "Parse error"
    end

    test "preserves defmodule structure" do
      code = """
      defmodule Foo do
        def bar, do: :ok
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [{:__aliases__, _, [:Foo]}, [do: _body]]} = expanded
    end

    test "preserves def structure while expanding body" do
      code = """
      defmodule Foo do
        def bar(x) do
          unless x, do: :fallback
        end
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: body]]} = expanded
      assert {:def, _, [{:bar, _, _}, [do: case_expr]]} = body
      assert {:case, _, _} = case_expr
    end

    test "preserves defp structure" do
      code = """
      defmodule Foo do
        defp secret(x), do: unless(x, do: :hidden)
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: defp_node]]} = expanded
      assert {:defp, _, [{:secret, _, _}, [do: {:case, _, _}]]} = defp_node
    end
  end

  describe "expand/2 with pre-parsed AST" do
    test "expands unless AST" do
      {:ok, ast} = Code.string_to_quoted("unless true, do: :never")
      {:ok, expanded} = ExPanda.expand(ast)
      assert {:case, _, _} = expanded
    end

    test "expands pipe AST" do
      {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      {:ok, expanded} = ExPanda.expand(ast)
      assert {{:., _, [String.Chars, :to_string]}, _, [1]} = expanded
    end

    test "passes through literals unchanged" do
      assert {:ok, 42} = ExPanda.expand(42)
      assert {:ok, :atom} = ExPanda.expand(:atom)
      assert {:ok, "string"} = ExPanda.expand("string")
    end
  end

  describe "expand/3 with explicit env" do
    test "returns expanded AST and final env" do
      env = ExPanda.EnvManager.new_env()
      {:ok, ast} = Code.string_to_quoted("unless true, do: :never")
      {:ok, expanded, final_env} = ExPanda.expand(ast, env, [])
      assert {:case, _, _} = expanded
      assert %Macro.Env{} = final_env
    end
  end

  describe "expand_file/2" do
    test "returns error for nonexistent file" do
      assert {:error, msg} = ExPanda.expand_file("/nonexistent/path.ex")
      assert msg =~ "Cannot read file"
    end
  end

  describe "unexpanded marker" do
    test "use NonExistentModule expands to require + __using__" do
      # `use` is a Kernel macro, it always expands even if the target module
      # doesn't exist. The expansion produces `require Mod; Mod.__using__([])`.
      code = """
      defmodule Foo do
        use NonExistentModule
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: body]]} = expanded
      # The use expanded to a block with require + __using__ call
      assert {:__block__, _, _stmts} = body
    end

    test "mark_unexpanded produces @unexpanded marker" do
      node = {:some_macro, [], [:arg]}
      result = ExPanda.Walker.mark_unexpanded(node, "test reason")
      assert {:__block__, [], [marker, ^node]} = result
      assert {:@, [], [{:unexpanded, [], [desc]}]} = marker
      assert desc =~ "test reason"
    end
  end

  describe "directive env threading" do
    test "alias updates environment" do
      code = """
      defmodule Foo do
        alias String, as: S
        def bar, do: :ok
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: _]]} = expanded
    end

    test "import updates environment" do
      code = """
      defmodule Foo do
        import Enum, only: [map: 2]
        def bar, do: :ok
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: _]]} = expanded
    end

    test "require updates environment" do
      code = """
      defmodule Foo do
        require Logger
        def bar, do: :ok
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: _]]} = expanded
    end
  end

  describe "complex constructs" do
    test "expands macros inside case bodies" do
      code = """
      defmodule Foo do
        def bar(x) do
          case x do
            :a -> unless(true, do: 1)
            _ -> :ok
          end
        end
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: def_node]]} = expanded
      assert {:def, _, [{:bar, _, _}, [do: {:case, _, _}]]} = def_node
    end

    test "handles fn clauses" do
      code = """
      defmodule Foo do
        def bar do
          fn x -> unless(x, do: :no) end
        end
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: def_node]]} = expanded
      assert {:def, _, [{:bar, _, _}, [do: {:fn, _, _clauses}]]} = def_node
    end

    test "handles module attributes" do
      code = """
      defmodule Foo do
        @moduledoc false
        def bar, do: :ok
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: {:__block__, _, stmts}]]} = expanded
      assert [{:@, _, [{:moduledoc, _, [false]}]} | _] = stmts
    end
  end
end
