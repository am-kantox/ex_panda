defmodule ExPanda.EnvManagerTest do
  use ExUnit.Case, async: true

  alias ExPanda.EnvManager

  doctest ExPanda.EnvManager

  describe "new_env/0" do
    test "creates a Macro.Env struct" do
      env = EnvManager.new_env()
      assert %Macro.Env{} = env
    end

    test "includes Kernel in requires" do
      env = EnvManager.new_env()
      assert Kernel in env.requires
    end

    test "includes Kernel functions" do
      env = EnvManager.new_env()
      kernel_fns = Keyword.get(env.functions, Kernel, [])
      assert {:+, 2} in kernel_fns
    end
  end

  describe "enter_module/2" do
    test "sets module name" do
      env = EnvManager.new_env() |> EnvManager.enter_module(Foo.Bar)
      assert env.module == Foo.Bar
    end

    test "resets function context" do
      env =
        EnvManager.new_env()
        |> EnvManager.enter_function(:test, 0, [])
        |> EnvManager.enter_module(Foo)

      assert env.function == nil
    end

    test "adds to context_modules" do
      env = EnvManager.new_env() |> EnvManager.enter_module(Foo)
      assert Foo in env.context_modules
    end
  end

  describe "enter_function/4" do
    test "sets function name and arity" do
      env = EnvManager.new_env() |> EnvManager.enter_function(:bar, 2, [:x, :y])
      assert env.function == {:bar, 2}
    end

    test "registers parameter variables" do
      env = EnvManager.new_env() |> EnvManager.enter_function(:bar, 2, [:x, :y])
      assert Map.has_key?(env.versioned_vars, {:x, nil})
      assert Map.has_key?(env.versioned_vars, {:y, nil})
    end
  end

  describe "apply_alias/3" do
    test "adds short alias" do
      env = EnvManager.new_env() |> EnvManager.apply_alias(Foo.Bar.Baz, nil)
      assert Keyword.has_key?(env.aliases, :"Elixir.Baz")
    end

    test "adds alias with :as option" do
      env = EnvManager.new_env() |> EnvManager.apply_alias(Foo.Bar, :FB)
      assert Keyword.has_key?(env.aliases, :"Elixir.FB")
    end
  end

  describe "apply_import/3" do
    test "imports Enum functions" do
      env = EnvManager.new_env() |> EnvManager.apply_import(Enum)
      enum_fns = Keyword.get(env.functions, Enum, [])
      assert {:map, 2} in enum_fns
    end

    test "handles unavailable module gracefully" do
      env = EnvManager.new_env() |> EnvManager.apply_import(NonExistentModule)
      assert %Macro.Env{} = env
    end
  end

  describe "apply_require/2" do
    test "adds module to requires" do
      env = EnvManager.new_env() |> EnvManager.apply_require(Logger)
      assert Logger in env.requires
    end

    test "does not duplicate" do
      env =
        EnvManager.new_env()
        |> EnvManager.apply_require(Logger)
        |> EnvManager.apply_require(Logger)

      count = Enum.count(env.requires, &(&1 == Logger))
      assert count == 1
    end
  end

  describe "register_var/2" do
    test "registers a variable" do
      env = EnvManager.new_env() |> EnvManager.register_var(:x)
      assert Map.has_key?(env.versioned_vars, {:x, nil})
    end

    test "does not overwrite existing var" do
      env =
        EnvManager.new_env()
        |> EnvManager.register_var(:x)
        |> EnvManager.register_var(:x)

      assert Map.has_key?(env.versioned_vars, {:x, nil})
    end
  end

  describe "resolve_module_name/2" do
    test "resolves __aliases__" do
      assert EnvManager.resolve_module_name(
               {:__aliases__, [], [:Foo, :Bar]},
               EnvManager.new_env()
             ) == Foo.Bar
    end

    test "resolves bare atom" do
      assert EnvManager.resolve_module_name(String, EnvManager.new_env()) == String
    end

    test "returns nil for unresolvable" do
      assert EnvManager.resolve_module_name(42, EnvManager.new_env()) == nil
    end
  end

  describe "extract_param_names/1" do
    test "extracts simple params" do
      assert EnvManager.extract_param_names([{:x, [], nil}, {:y, [], nil}]) == [:x, :y]
    end

    test "extracts from pattern match" do
      params = [{:=, [], [{:x, [], nil}, {:y, [], nil}]}]
      names = EnvManager.extract_param_names(params)
      assert :x in names
      assert :y in names
    end

    test "skips underscore vars" do
      params = [{:_, [], nil}, {:_ignored, [], nil}, {:x, [], nil}]
      assert EnvManager.extract_param_names(params) == [:x]
    end

    test "extracts from default values" do
      params = [{:\\, [], [{:x, [], nil}, 42]}]
      assert EnvManager.extract_param_names(params) == [:x]
    end
  end

  describe "register_pattern_vars/2" do
    test "registers all vars from a tuple pattern" do
      env = EnvManager.new_env()
      pattern = {:{}, [], [{:a, [], nil}, {:b, [], nil}]}
      env = EnvManager.register_pattern_vars(env, pattern)
      assert Map.has_key?(env.versioned_vars, {:a, nil})
      assert Map.has_key?(env.versioned_vars, {:b, nil})
    end
  end
end
