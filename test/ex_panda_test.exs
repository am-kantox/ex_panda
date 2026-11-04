defmodule ExPandaTest do
  use ExUnit.Case, async: true

  doctest ExPanda

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
    test "use NonExistentModule gets @unexpanded marker" do
      code = """
      defmodule Foo do
        use NonExistentModule
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: body]]} = expanded
      # Module not available, so use is marked as unexpanded
      assert {:__block__, [], [marker, {:use, _, _}]} = body
      assert {:@, [], [{:unexpanded, [], [desc]}]} = marker
      assert desc =~ "not available"
    end

    test "mark_unexpanded produces @unexpanded marker" do
      node = {:some_macro, [], [:arg]}
      result = ExPanda.Walker.mark_unexpanded(node, "test reason")
      assert {:__block__, [], [marker, ^node]} = result
      assert {:@, [], [{:unexpanded, [], [desc]}]} = marker
      assert desc =~ "test reason"
    end
  end

  describe "use expansion" do
    test "use GenServer inside defmodule expands successfully" do
      code = """
      defmodule Foo do
        use GenServer
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: body]]} = expanded
      # Should produce require GenServer + expanded __using__ code (no @unexpanded markers)
      assert {:__block__, [], [{:require, [], [GenServer]} | _rest]} = body
      # No @unexpanded markers in the output
      refute ast_contains_unexpanded?(expanded)
    end

    test "use GenServer expands @behaviour and def child_spec" do
      code = """
      defmodule Foo do
        use GenServer
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      expanded_str = Macro.to_string(expanded)
      assert expanded_str =~ "@behaviour GenServer"
      assert expanded_str =~ "child_spec"
    end

    test "use with options" do
      code = """
      defmodule Foo do
        use GenServer, restart: :transient
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: body]]} = expanded
      assert {:__block__, [], [{:require, [], [GenServer]} | _]} = body
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

  describe "defdelegate expansion" do
    test "expands defdelegate into a def calling the target module" do
      code = """
      defmodule Foo do
        defdelegate bar(x), to: Baz
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: def_node]]} = expanded
      assert {:def, _, [{:bar, _, [{:x, _, _}]}, [do: call]]} = def_node
      # `:to` is resolved to the module atom, matching compiled behaviour.
      assert {{:., _, [Baz, :bar]}, _, [{:x, _, _}]} = call
    end

    test "expands defdelegate with :as option" do
      code = """
      defmodule Foo do
        defdelegate bar(x), to: Baz, as: :quux
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: def_node]]} = expanded
      assert {:def, _, [{:bar, _, _}, [do: call]]} = def_node
      assert {{:., _, [Baz, :quux]}, _, _} = call
    end

    test "expands zero-arity defdelegate without parentheses" do
      code = """
      defmodule Foo do
        defdelegate bar, to: Baz
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: def_node]]} = expanded
      assert {:def, _, [{:bar, _, []}, [do: call]]} = def_node
      assert {{:., _, [Baz, :bar]}, _, []} = call
    end

    test "expands list form of defdelegate into multiple defs" do
      code = """
      defmodule Foo do
        defdelegate [bar(x), baz(y)], to: Baz
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: {:__block__, _, [first, second]}]]} = expanded
      assert {:def, _, [{:bar, _, _}, [do: {{:., _, [_, :bar]}, _, _}]]} = first
      assert {:def, _, [{:baz, _, _}, [do: {{:., _, [_, :baz]}, _, _}]]} = second
    end

    test "does not leave an @unexpanded marker" do
      code = """
      defmodule Foo do
        defdelegate bar(x), to: Baz
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      refute ast_contains_unexpanded?(expanded)
    end

    test "expands macros in sibling statements after a defdelegate" do
      code = """
      defmodule Foo do
        defdelegate bar(x), to: String, as: :upcase
        def baz, do: unless(true, do: :no)
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert {:defmodule, _, [_, [do: {:__block__, _, [_, baz_def]}]]} = expanded
      assert {:def, _, [{:baz, _, _}, [do: {:case, _, _}]]} = baz_def
    end

    test "marks defdelegate without :to as unexpanded" do
      code = """
      defmodule Foo do
        defdelegate bar(x)
      end
      """

      {:ok, expanded} = ExPanda.expand_string(code)
      assert ast_contains_unexpanded?(expanded)
    end
  end

  describe "with/for keyword options stay a single trailing list" do
    test "with keeps do: as a keyword pair, not a positional arg" do
      {:ok, out} = ExPanda.expand_to_string("with {:ok, x} <- {:ok, 1}, do: x")
      {:ok, reparsed} = Code.string_to_quoted(out)

      assert {:with, _, args} = reparsed
      assert is_list(List.last(args))
      assert Keyword.keyword?(List.last(args))
      assert Keyword.has_key?(List.last(args), :do)
    end

    test "with keeps else: alongside do:" do
      {:ok, out} = ExPanda.expand_to_string("with {:ok, x} <- f(), do: x, else: (_ -> :err)")
      {:ok, {:with, _, args}} = Code.string_to_quoted(out)

      opts = List.last(args)
      assert Keyword.keyword?(opts)
      assert Keyword.has_key?(opts, :do)
      assert Keyword.has_key?(opts, :else)
    end

    test "for keeps do: as a keyword pair" do
      {:ok, out} = ExPanda.expand_to_string("for x <- [1, 2], do: x * 2")
      {:ok, {:for, _, args}} = Code.string_to_quoted(out)

      assert Keyword.keyword?(List.last(args))
      assert Keyword.has_key?(List.last(args), :do)
    end

    test "for keeps into: and do: together" do
      {:ok, out} = ExPanda.expand_to_string("for x <- [1, 2], into: %{}, do: {x, x}")
      {:ok, {:for, _, args}} = Code.string_to_quoted(out)

      opts = List.last(args)
      assert Keyword.keyword?(opts)
      assert Keyword.has_key?(opts, :into)
      assert Keyword.has_key?(opts, :do)
    end

    test "for keeps reduce: and do:" do
      {:ok, out} = ExPanda.expand_to_string("for x <- [1, 2], reduce: 0, do: (acc -> acc + x)")
      {:ok, {:for, _, args}} = Code.string_to_quoted(out)

      opts = List.last(args)
      assert Keyword.keyword?(opts)
      assert Keyword.has_key?(opts, :reduce)
    end

    test "for keeps filters alongside generators" do
      {:ok, out} = ExPanda.expand_to_string("for x <- [1, 2], x > 1, do: x")
      {:ok, {:for, _, args}} = Code.string_to_quoted(out)

      assert Keyword.keyword?(List.last(args))
    end
  end

  # --- Test Helpers ---

  defp ast_contains_unexpanded?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{:unexpanded, _, _}]} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end
end
