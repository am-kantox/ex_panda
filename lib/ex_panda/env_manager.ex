defmodule ExPanda.EnvManager do
  @moduledoc """
  Manages `Macro.Env` structs for macro expansion.

  Handles environment construction, updates for compilation directives
  (`alias`, `import`, `require`), module/function scoping, and variable
  registration for `:elixir_expand` compatibility.
  """

  @doc """
  Create a fresh compilation environment using Elixir's internal env factory.

  This produces a `Macro.Env` with Kernel functions and macros pre-loaded,
  matching what a new module compilation would start with.

  ## Examples

      iex> env = ExPanda.EnvManager.new_env()
      iex> env.__struct__
      Macro.Env
      iex> Kernel in env.requires
      true
  """
  @spec new_env() :: Macro.Env.t()
  def new_env do
    :elixir_env.new()
  end

  @doc """
  Create an environment from the caller's current context.

  Useful when expanding code within a running application where
  all dependencies are already loaded.
  """
  @spec from_caller(Macro.Env.t()) :: Macro.Env.t()
  def from_caller(caller_env) do
    caller_env
  end

  @doc """
  Set the file path in the environment.
  """
  @spec put_file(Macro.Env.t(), String.t()) :: Macro.Env.t()
  def put_file(env, path) do
    %{env | file: path}
  end

  @doc """
  Set the line number in the environment.
  """
  @spec put_line(Macro.Env.t(), non_neg_integer()) :: Macro.Env.t()
  def put_line(env, line) do
    %{env | line: line}
  end

  @doc """
  Create a child environment for a module scope.

  Sets the module name and resets function context.
  """
  @spec enter_module(Macro.Env.t(), module()) :: Macro.Env.t()
  def enter_module(env, module_name) do
    %{
      env
      | module: module_name,
        function: nil,
        context_modules: [module_name | env.context_modules]
    }
  end

  @doc """
  Create a child environment for a function scope.

  Sets the function name/arity and registers parameters as variables.
  """
  @spec enter_function(Macro.Env.t(), atom(), non_neg_integer(), list()) :: Macro.Env.t()
  def enter_function(env, name, arity, param_names) do
    versioned_vars =
      Enum.reduce(param_names, env.versioned_vars, fn var_name, acc ->
        Map.put(acc, {var_name, nil}, {0, :term})
      end)

    %{env | function: {name, arity}, versioned_vars: versioned_vars}
  end

  @doc """
  Apply an `alias` directive to the environment.

  Handles both `alias Foo.Bar` (aliasing `Bar`) and `alias Foo.Bar, as: Baz`.

  ## Examples

      iex> env = ExPanda.EnvManager.new_env()
      iex> env = ExPanda.EnvManager.apply_alias(env, Foo.Bar, nil)
      iex> {Foo.Bar, Bar} in env.aliases or Keyword.get(env.aliases, :"Elixir.Bar") == Foo.Bar
      true
  """
  @spec apply_alias(Macro.Env.t(), module(), module() | nil) :: Macro.Env.t()
  def apply_alias(env, module, nil) do
    short_name = module |> Module.split() |> List.last() |> String.to_atom()
    full_alias = Module.concat([Elixir, short_name])
    %{env | aliases: Keyword.put(env.aliases, full_alias, module)}
  end

  def apply_alias(env, module, as_name) do
    full_alias = Module.concat([Elixir, as_name])
    %{env | aliases: Keyword.put(env.aliases, full_alias, module)}
  end

  @doc """
  Apply an `import` directive to the environment.

  Loads the target module's functions and macros into the env.
  Returns the env unchanged if the module is not available.
  """
  @spec apply_import(Macro.Env.t(), module(), keyword()) :: Macro.Env.t()
  def apply_import(env, module, opts \\ []) do
    only = Keyword.get(opts, :only)

    with true <- Code.ensure_loaded?(module),
         functions <- module.__info__(:functions),
         macros <- module.__info__(:macros) do
      {filtered_fns, filtered_macros} = filter_imports(functions, macros, only)

      %{
        env
        | functions: [{module, filtered_fns} | env.functions],
          macros: [{module, filtered_macros} | env.macros]
      }
    else
      _ -> env
    end
  rescue
    _ -> env
  end

  @doc """
  Apply a `require` directive to the environment.

  Adds the module to the requires list if not already present.
  """
  @spec apply_require(Macro.Env.t(), module()) :: Macro.Env.t()
  def apply_require(env, module) do
    if module in env.requires do
      env
    else
      %{env | requires: [module | env.requires]}
    end
  end

  @doc """
  Register a variable name in the environment's versioned_vars.

  This is needed for `:elixir_expand.expand/3` which raises on undefined variables.
  """
  @spec register_var(Macro.Env.t(), atom()) :: Macro.Env.t()
  def register_var(env, name) when is_atom(name) do
    key = {name, nil}

    if Map.has_key?(env.versioned_vars, key) do
      env
    else
      %{env | versioned_vars: Map.put(env.versioned_vars, key, {0, :term})}
    end
  end

  @doc """
  Register multiple variable names extracted from a pattern AST.

  Walks the pattern to find all variable bindings and registers them.
  """
  @spec register_pattern_vars(Macro.Env.t(), Macro.t()) :: Macro.Env.t()
  def register_pattern_vars(env, pattern) do
    vars = extract_var_names(pattern)
    Enum.reduce(vars, env, &register_var(&2, &1))
  end

  @doc """
  Extract the module name from an alias AST node.

  ## Examples

      iex> ExPanda.EnvManager.resolve_module_name({:__aliases__, [], [:Foo, :Bar]}, ExPanda.EnvManager.new_env())
      Foo.Bar
  """
  @spec resolve_module_name(Macro.t(), Macro.Env.t()) :: module()
  def resolve_module_name({:__aliases__, _, parts}, _env) do
    Module.concat(parts)
  end

  def resolve_module_name(atom, _env) when is_atom(atom), do: atom
  def resolve_module_name(_, _env), do: nil

  @doc """
  Extract parameter names from a function signature AST.

  Handles simple params, pattern params, default values, and guards.

  ## Examples

      iex> ExPanda.EnvManager.extract_param_names([{:x, [], nil}, {:y, [], nil}])
      [:x, :y]
  """
  @spec extract_param_names(list()) :: [atom()]
  def extract_param_names(params) when is_list(params) do
    Enum.flat_map(params, &extract_var_names/1)
  end

  def extract_param_names(_), do: []

  # --- Private ---

  defp filter_imports(functions, macros, nil), do: {functions, macros}

  defp filter_imports(functions, _macros, :functions) do
    {functions, []}
  end

  defp filter_imports(_functions, macros, :macros) do
    {[], macros}
  end

  defp filter_imports(functions, macros, only) when is_list(only) do
    filtered_fns = Enum.filter(functions, fn {name, arity} -> {name, arity} in only end)
    filtered_macros = Enum.filter(macros, fn {name, arity} -> {name, arity} in only end)
    {filtered_fns, filtered_macros}
  end

  defp extract_var_names({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    if name == :_ or String.starts_with?(Atom.to_string(name), "_") do
      []
    else
      [name]
    end
  end

  defp extract_var_names({:=, _, [left, right]}) do
    extract_var_names(left) ++ extract_var_names(right)
  end

  defp extract_var_names({:{}, _, elements}) do
    Enum.flat_map(elements, &extract_var_names/1)
  end

  defp extract_var_names({left, right}) do
    extract_var_names(left) ++ extract_var_names(right)
  end

  defp extract_var_names(list) when is_list(list) do
    Enum.flat_map(list, &extract_var_names/1)
  end

  defp extract_var_names({:\\, _, [param, _default]}) do
    extract_var_names(param)
  end

  defp extract_var_names({:%, _, [_struct, {:%{}, _, pairs}]}) do
    Enum.flat_map(pairs, fn {_key, val} -> extract_var_names(val) end)
  end

  defp extract_var_names({:%{}, _, pairs}) do
    Enum.flat_map(pairs, fn {_key, val} -> extract_var_names(val) end)
  end

  defp extract_var_names(_), do: []
end
