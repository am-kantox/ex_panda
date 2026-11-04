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

    test "expands pipe operator by default" do
      {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())
      assert {{:., _, [String.Chars, :to_string]}, _, [1]} = expanded
    end

    test "preserves pipe operator with expand_operators: false" do
      {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)
      assert {:|>, _, [1, _call]} = expanded
    end
  end

  describe "operator preservation" do
    test "preserves arithmetic operators instead of lowering to :erlang BIFs" do
      for src <- ["1 + 2", "a - b", "a * b", "a / b"] do
        {:ok, ast} = Code.string_to_quoted(src)
        {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)

        assert {op, _, [_, _]} = expanded
        assert op in [:+, :-, :*, :/]
        refute match?({{:., _, [:erlang, _]}, _, _}, expanded)
      end
    end

    test "preserves Kernel macro operators" do
      cases = [
        {"a <> b", :<>},
        {"a && b", :&&},
        {"a || b", :||},
        {"a in b", :in},
        {"a and b", :and},
        {"a or b", :or},
        {"a ++ b", :++}
      ]

      for {src, expected_op} <- cases do
        {:ok, ast} = Code.string_to_quoted(src)
        {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)
        assert {^expected_op, _, [_, _]} = expanded
      end
    end

    test "preserves comparison operators" do
      for src <- ["a == b", "a != b", "a === b", "a < b", "a > b", "a <= b", "a >= b"] do
        {:ok, ast} = Code.string_to_quoted(src)
        {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)
        assert {op, _, [_, _]} = expanded
        assert op in [:==, :!=, :===, :<, :>, :<=, :>=]
      end
    end

    test "preserves unary operators" do
      {:ok, ast} = Code.string_to_quoted("not a")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)
      assert {:not, _, [_]} = expanded

      {:ok, ast} = Code.string_to_quoted("-a")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)
      assert {:-, _, [_]} = expanded
    end

    test "still expands macros nested inside operator operands" do
      {:ok, ast} = Code.string_to_quoted("x + unless(true, do: 1)")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)

      assert {:+, _, [_, {:case, _, _}]} = expanded
    end
  end

  describe "expand_operators option" do
    test "defaults to true (backward compatible)" do
      {:ok, ast} = Code.string_to_quoted("1 + 2")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())

      assert {{:., _, [:erlang, :+]}, _, [1, 2]} = expanded
    end

    test "explicit true matches the default" do
      {:ok, ast} = Code.string_to_quoted("1 + 2")
      {default, _} = Walker.walk(ast, EnvManager.new_env())
      {explicit, _} = Walker.walk(ast, EnvManager.new_env(), expand_operators: true)

      assert default == explicit
    end

    test "false preserves operators" do
      {:ok, ast} = Code.string_to_quoted("1 + 2")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)

      assert {:+, _, [1, 2]} = expanded
    end

    test "false still expands macros nested in operands" do
      {:ok, ast} = Code.string_to_quoted("x + unless(true, do: 1)")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)

      assert {:+, _, [_, {:case, _, _}]} = expanded
    end

    test "false does not affect non-operator macro expansion" do
      {:ok, ast} = Code.string_to_quoted("unless true, do: :never")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)

      assert {:case, _, _} = expanded
    end

    test "the option survives nested constructs" do
      src = """
      defmodule Foo do
        def bar(x), do: x + 1
      end
      """

      {:ok, ast} = Code.string_to_quoted(src)
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env(), expand_operators: false)

      assert {:defmodule, _, [_, [do: {:def, _, [_, [do: {:+, _, [_, 1]}]]}]]} = expanded
    end
  end

  describe "capture operator" do
    test "preserves remote capture &Mod.fun/arity" do
      {:ok, ast} = Code.string_to_quoted("&Enum.map/2")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())

      # The capture body is left untouched, so the alias node is preserved.
      assert {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, []}, 2]}]} =
               expanded

      refute match?({:&, _, [{{:., _, [:erlang, _]}, _, _}]}, expanded)
    end

    test "preserves local capture &fun/arity" do
      {:ok, ast} = Code.string_to_quoted("&to_string/1")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())

      assert {:&, _, [{:/, _, [{:to_string, _, _}, 1]}]} = expanded
    end

    test "preserves anonymous capture with placeholders" do
      {:ok, ast} = Code.string_to_quoted("&(&1 + 1)")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())

      assert {:&, _, [{:+, _, [{:&, _, [1]}, 1]}]} = expanded
    end

    test "preserves capture with multiple placeholders" do
      {:ok, ast} = Code.string_to_quoted("&(&1 + &2)")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())

      assert {:&, _, [{:+, _, [{:&, _, [1]}, {:&, _, [2]}]}]} = expanded
    end

    test "capture output round-trips through formatted source" do
      for src <- ["&Enum.map/2", "&to_string/1", "&(&1 + 1)", "&(&1 + &2)"] do
        assert {:ok, out} = ExPanda.expand_to_string(src)
        assert {:ok, _} = Code.string_to_quoted(out)
      end
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

  describe "defdelegate expansion" do
    test "expands defdelegate to a def with a remote call" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do defdelegate bar(x), to: Baz end")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())

      assert {:defmodule, _, [_, [do: {:def, _, [{:bar, _, _}, [do: call]]}]]} = expanded
      assert {{:., _, [Baz, :bar]}, _, _} = call
    end

    test "expands list form into a block of defs" do
      {:ok, ast} = Code.string_to_quoted("defmodule Foo do defdelegate [a(x), b(y)], to: Baz end")
      {expanded, _env} = Walker.walk(ast, EnvManager.new_env())

      assert {:defmodule, _, [_, [do: {:__block__, _, [_, _]}]]} = expanded
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
