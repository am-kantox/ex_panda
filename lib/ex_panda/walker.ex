defmodule ExPanda.Walker do
  @moduledoc """
  Recursive AST walker that expands macros while preserving structural forms.

  The walker traverses the AST top-down, applying these rules:

  1. **Structural forms** (`defmodule`, `def`/`defp`, `defmacro`/`defmacrop`):
     preserved as-is, with their bodies recursively expanded.
  2. **Directives** (`alias`, `import`, `require`): applied to the environment
     for subsequent expansions, preserved in output.
  3. **`use`**: expanded by calling `MACRO-__using__/2` directly, then re-walked.
  4. **Blocks** (`__block__`): each statement walked sequentially, threading the env.
  5. **Expressions**: expanded via `:elixir_expand.expand/3` (or `Macro.expand/2` fallback).
  6. **Failures**: unexpandable nodes are kept with an `@unexpanded` marker prepended.
  """

  alias ExPanda.{CompilerExpand, EnvManager}

  @func_types [:def, :defp, :defmacro, :defmacrop]

  @doc """
  Walk and expand the AST starting from the given environment.

  Returns `{expanded_ast, final_env}`.
  """
  @spec walk(Macro.t(), Macro.Env.t()) :: {Macro.t(), Macro.Env.t()}
  def walk(ast, env) do
    do_walk(ast, env)
  end

  # --- Structural Forms ---

  # defmodule Name do ... end
  defp do_walk({:defmodule, meta, [alias_ast, [do: body]]}, env) do
    module_name = EnvManager.resolve_module_name(alias_ast, env)
    module_env = EnvManager.enter_module(env, module_name)
    {expanded_body, _module_env} = do_walk(body, module_env)
    {{:defmodule, meta, [alias_ast, [do: expanded_body]]}, env}
  end

  # defmodule Name do ... end (with other keyword options like @derive, etc.)
  defp do_walk({:defmodule, meta, [alias_ast, opts]}, env) when is_list(opts) do
    module_name = EnvManager.resolve_module_name(alias_ast, env)
    module_env = EnvManager.enter_module(env, module_name)

    expanded_opts =
      Enum.map(opts, fn
        {:do, body} ->
          {expanded_body, _} = do_walk(body, module_env)
          {:do, expanded_body}

        other ->
          other
      end)

    {{:defmodule, meta, [alias_ast, expanded_opts]}, env}
  end

  # def/defp with guards: def foo(x) when is_integer(x), do: ...
  defp do_walk(
         {func_type, meta, [{:when, when_meta, [{name, sig_meta, args} | guards]}, [do: body]]},
         env
       )
       when func_type in @func_types and is_atom(name) do
    params = if is_list(args), do: args, else: []
    arity = length(params)
    param_names = EnvManager.extract_param_names(params)
    func_env = EnvManager.enter_function(env, name, arity, param_names)

    {expanded_body, _} = do_walk(body, func_env)

    expanded_guards =
      Enum.map(guards, fn guard ->
        case try_expand_expression(guard, func_env) do
          {:ok, expanded, _} -> expanded
          {:error, _} -> guard
        end
      end)

    sig = {:when, when_meta, [{name, sig_meta, args} | expanded_guards]}
    {{func_type, meta, [sig, [do: expanded_body]]}, env}
  end

  # def/defp with keyword body: def foo(x), do: ...
  defp do_walk({func_type, meta, [{name, sig_meta, args}, [do: body]]}, env)
       when func_type in @func_types and is_atom(name) do
    params = if is_list(args), do: args, else: []
    arity = length(params)
    param_names = EnvManager.extract_param_names(params)
    func_env = EnvManager.enter_function(env, name, arity, param_names)

    {expanded_body, _} = do_walk(body, func_env)
    {{func_type, meta, [{name, sig_meta, args}, [do: expanded_body]]}, env}
  end

  # def/defp with do..end block: def foo(x) do ... end
  defp do_walk({func_type, meta, [{name, sig_meta, args}, opts]}, env)
       when func_type in @func_types and is_atom(name) and is_list(opts) do
    params = if is_list(args), do: args, else: []
    arity = length(params)
    param_names = EnvManager.extract_param_names(params)
    func_env = EnvManager.enter_function(env, name, arity, param_names)

    expanded_opts =
      Enum.map(opts, fn
        {:do, body} ->
          {expanded_body, _} = do_walk(body, func_env)
          {:do, expanded_body}

        {:rescue, clauses} ->
          expanded_clauses = Enum.map(clauses, &expand_clause(&1, func_env))
          {:rescue, expanded_clauses}

        {:catch, clauses} ->
          expanded_clauses = Enum.map(clauses, &expand_clause(&1, func_env))
          {:catch, expanded_clauses}

        {:after, body} ->
          {expanded_body, _} = do_walk(body, func_env)
          {:after, expanded_body}

        other ->
          other
      end)

    {{func_type, meta, [{name, sig_meta, args}, expanded_opts]}, env}
  end

  # --- Directives ---

  # alias Foo.Bar or alias Foo.Bar, as: Baz
  defp do_walk({:alias, meta, [{:__aliases__, _, parts} | opts_rest]}, env) do
    module = Module.concat(parts)
    as_name = get_alias_as(opts_rest)
    new_env = EnvManager.apply_alias(env, module, as_name)
    {{:alias, meta, [{:__aliases__, [], parts} | opts_rest]}, new_env}
  end

  # import Foo or import Foo, only: [...]
  defp do_walk({:import, meta, [target | opts_rest]}, env) do
    module = EnvManager.resolve_module_name(target, env) || target
    import_opts = List.first(opts_rest) || []
    new_env = EnvManager.apply_import(env, module, import_opts)
    {{:import, meta, [target | opts_rest]}, new_env}
  end

  # require Foo
  defp do_walk({:require, meta, [target | rest]}, env) do
    module = EnvManager.resolve_module_name(target, env) || target

    new_env =
      if is_atom(module), do: EnvManager.apply_require(env, module), else: env

    {{:require, meta, [target | rest]}, new_env}
  end

  # use Foo, opts -- call __using__ macro directly to bypass module table dispatch.
  # The standard Macro.expand path fails inside defmodule because enter_module
  # sets env.module without creating the compiler's ETS module table.
  # Calling MACRO-__using__/2 directly avoids the dispatch check.
  defp do_walk({:use, _meta, args} = node, env) do
    with {:ok, module, opts} <- resolve_use_module(args, env),
         new_env = EnvManager.apply_require(env, module),
         {:ok, quoted} <- invoke_using_macro(module, opts, new_env) do
      {expanded, final_env} = do_walk(quoted, new_env)
      result = {:__block__, [], [{:require, [], [module]}, expanded]}
      {result, final_env}
    else
      {:error, reason} ->
        {mark_unexpanded(node, reason), env}
    end
  end

  # defoverridable: keep as-is (compile-time directive, needs module table)
  defp do_walk({:defoverridable, _meta, _args} = node, env) do
    {node, env}
  end

  # --- Block ---

  # __block__: walk each statement sequentially, threading env
  defp do_walk({:__block__, meta, statements}, env) when is_list(statements) do
    {expanded_stmts, final_env} =
      Enum.map_reduce(statements, env, fn stmt, acc_env ->
        do_walk(stmt, acc_env)
      end)

    {{:__block__, meta, expanded_stmts}, final_env}
  end

  # --- Match operator: register bound variables ---

  defp do_walk({:=, meta, [pattern, value]}, env) do
    {expanded_value, env} = do_walk(value, env)
    env = EnvManager.register_pattern_vars(env, pattern)
    {expanded_pattern, env} = do_walk(pattern, env)
    {{:=, meta, [expanded_pattern, expanded_value]}, env}
  end

  # --- Case / Cond / With: expand children ---

  defp do_walk({:case, meta, [scrutinee, [do: clauses]]}, env) do
    {expanded_scrutinee, env} = do_walk(scrutinee, env)

    expanded_clauses =
      Enum.map(clauses, fn {:->, arrow_meta, [patterns, body]} ->
        clause_env = register_clause_vars(env, patterns)
        {expanded_body, _} = do_walk(body, clause_env)
        {:->, arrow_meta, [patterns, expanded_body]}
      end)

    {{:case, meta, [expanded_scrutinee, [do: expanded_clauses]]}, env}
  end

  defp do_walk({:cond, meta, [[do: clauses]]}, env) do
    expanded_clauses =
      Enum.map(clauses, fn {:->, arrow_meta, [condition, body]} ->
        {expanded_cond, _} = do_walk(condition, env)
        {expanded_body, _} = do_walk(body, env)
        {:->, arrow_meta, [expanded_cond, expanded_body]}
      end)

    {{:cond, meta, [[do: expanded_clauses]]}, env}
  end

  defp do_walk({:with, meta, args}, env) when is_list(args) do
    {clauses, body_opts} = split_with_clauses(args)

    {expanded_clauses, with_env} =
      Enum.map_reduce(clauses, env, fn
        {:<-, arrow_meta, [pattern, expr]}, acc_env ->
          {expanded_expr, acc_env} = do_walk(expr, acc_env)
          acc_env = EnvManager.register_pattern_vars(acc_env, pattern)
          {{:<-, arrow_meta, [pattern, expanded_expr]}, acc_env}

        other, acc_env ->
          do_walk(other, acc_env)
      end)

    expanded_opts =
      Enum.map(body_opts, fn
        {:do, body} ->
          {expanded, _} = do_walk(body, with_env)
          {:do, expanded}

        {:else, clauses} ->
          expanded =
            Enum.map(clauses, fn {:->, am, [patterns, body]} ->
              clause_env = register_clause_vars(env, patterns)
              {expanded_body, _} = do_walk(body, clause_env)
              {:->, am, [patterns, expanded_body]}
            end)

          {:else, expanded}

        other ->
          other
      end)

    {{:with, meta, expanded_clauses ++ expanded_opts}, env}
  end

  # --- Try/Rescue/Catch ---

  defp do_walk({:try, meta, [opts]}, env) when is_list(opts) do
    expanded_opts =
      Enum.map(opts, fn
        {:do, body} ->
          {expanded, _} = do_walk(body, env)
          {:do, expanded}

        {:rescue, clauses} ->
          {:rescue, Enum.map(clauses, &expand_clause(&1, env))}

        {:catch, clauses} ->
          {:catch, Enum.map(clauses, &expand_clause(&1, env))}

        {:after, body} ->
          {expanded, _} = do_walk(body, env)
          {:after, expanded}

        {:else, clauses} ->
          expanded =
            Enum.map(clauses, fn {:->, am, [patterns, body]} ->
              clause_env = register_clause_vars(env, patterns)
              {expanded_body, _} = do_walk(body, clause_env)
              {:->, am, [patterns, expanded_body]}
            end)

          {:else, expanded}

        other ->
          other
      end)

    {{:try, meta, [expanded_opts]}, env}
  end

  # --- For comprehension ---

  defp do_walk({:for, meta, args}, env) when is_list(args) do
    {generators, body_opts} = split_for_clauses(args)

    {expanded_gens, for_env} =
      Enum.map_reduce(generators, env, fn
        {:<-, arrow_meta, [pattern, collection]}, acc_env ->
          {expanded_coll, acc_env} = do_walk(collection, acc_env)
          acc_env = EnvManager.register_pattern_vars(acc_env, pattern)
          {{:<-, arrow_meta, [pattern, expanded_coll]}, acc_env}

        filter, acc_env ->
          do_walk(filter, acc_env)
      end)

    expanded_opts =
      Enum.map(body_opts, fn
        {:do, body} ->
          {expanded, _} = do_walk(body, for_env)
          {:do, expanded}

        {:into, into} ->
          {expanded, _} = do_walk(into, env)
          {:into, expanded}

        {:reduce, init} ->
          {expanded, _} = do_walk(init, env)
          {:reduce, expanded}

        other ->
          other
      end)

    {{:for, meta, expanded_gens ++ expanded_opts}, env}
  end

  # --- fn clauses ---

  defp do_walk({:fn, meta, clauses}, env) when is_list(clauses) do
    expanded_clauses =
      Enum.map(clauses, fn {:->, arrow_meta, [params, body]} ->
        param_names = EnvManager.extract_param_names(params)
        clause_env = Enum.reduce(param_names, env, &EnvManager.register_var(&2, &1))
        {expanded_body, _} = do_walk(body, clause_env)
        {:->, arrow_meta, [params, expanded_body]}
      end)

    {{:fn, meta, expanded_clauses}, env}
  end

  # --- General expression expansion ---

  # Module attribute: keep as-is (structural)
  defp do_walk({:@, _meta, [{_name, _attr_meta, _}]} = node, env) do
    {node, env}
  end

  # Two-element tuple (e.g. keyword pair value): walk both elements
  defp do_walk({left, right}, env) do
    {expanded_left, env} = do_walk(left, env)
    {expanded_right, env} = do_walk(right, env)
    {{expanded_left, expanded_right}, env}
  end

  # List: walk each element
  defp do_walk(list, env) when is_list(list) do
    Enum.map_reduce(list, env, fn elem, acc_env ->
      do_walk(elem, acc_env)
    end)
  end

  # Literals: pass through
  defp do_walk(literal, env)
       when is_atom(literal) or is_number(literal) or is_binary(literal) do
    {literal, env}
  end

  # General 3-tuple AST node: try expanding as a macro
  defp do_walk({form, meta, args} = node, env) when is_atom(form) and is_list(args) do
    case try_expand_expression(node, env) do
      {:ok, ^node, new_env} ->
        # Not a macro -- recurse into children
        {expanded_args, env} =
          Enum.map_reduce(args, new_env, fn arg, acc_env ->
            do_walk(arg, acc_env)
          end)

        {{form, meta, expanded_args}, env}

      {:ok, expanded, new_env} ->
        # Macro expanded -- re-walk the result
        do_walk(expanded, new_env)

      {:error, reason} ->
        {mark_unexpanded(node, reason), env}
    end
  end

  # Remote call: {{:., meta, [module, fun]}, call_meta, args}
  defp do_walk({{:., dot_meta, [mod, fun]}, call_meta, args} = node, env)
       when is_atom(fun) and is_list(args) do
    case try_expand_expression(node, env) do
      {:ok, expanded, new_env} ->
        if expanded == node do
          {expanded_mod, env2} = do_walk(mod, new_env)
          {expanded_args, env3} = Enum.map_reduce(args, env2, &do_walk/2)
          {{{:., dot_meta, [expanded_mod, fun]}, call_meta, expanded_args}, env3}
        else
          do_walk(expanded, new_env)
        end

      {:error, reason} ->
        {mark_unexpanded(node, reason), env}
    end
  end

  # Catch-all for other AST forms
  defp do_walk(node, env), do: {node, env}

  # --- Helpers ---

  defp try_expand_expression(ast, env) do
    CompilerExpand.expand(ast, env)
  end

  defp expand_clause({:->, arrow_meta, [patterns, body]}, env) do
    clause_env = register_clause_vars(env, patterns)
    {expanded_body, _} = do_walk(body, clause_env)
    {:->, arrow_meta, [patterns, expanded_body]}
  end

  defp expand_clause(other, _env), do: other

  defp register_clause_vars(env, patterns) when is_list(patterns) do
    Enum.reduce(patterns, env, &EnvManager.register_pattern_vars(&2, &1))
  end

  defp register_clause_vars(env, pattern) do
    EnvManager.register_pattern_vars(env, pattern)
  end

  @doc false
  def mark_unexpanded(node, reason) do
    description = "#{format_node(node)}: #{reason}"
    marker = {:@, [], [{:unexpanded, [], [description]}]}
    {:__block__, [], [marker, node]}
  end

  defp format_node({form, _, args}) when is_atom(form) and is_list(args) do
    "#{form}/#{length(args)}"
  end

  defp format_node({form, _, _}) when is_atom(form), do: Atom.to_string(form)
  defp format_node(_), do: "expression"

  defp resolve_use_module(args, env) do
    case args do
      [module_ast | rest] ->
        module = EnvManager.resolve_module_name(module_ast, env)

        cond do
          not is_atom(module) or is_nil(module) ->
            {:error, "use: could not resolve module"}

          not Code.ensure_loaded?(module) ->
            {:error, "use: module #{inspect(module)} is not available"}

          true ->
            opts = List.first(rest) || []
            {:ok, module, opts}
        end

      _ ->
        {:error, "use: invalid arguments"}
    end
  end

  defp invoke_using_macro(module, opts, env) do
    macro_name = :"MACRO-__using__"

    if function_exported?(module, macro_name, 2) do
      try do
        quoted = apply(module, macro_name, [env, opts])
        {:ok, quoted}
      rescue
        e -> {:error, "use #{inspect(module)}: #{Exception.message(e)}"}
      end
    else
      {:error, "use #{inspect(module)}: __using__/1 macro not defined"}
    end
  end

  defp get_alias_as([]), do: nil

  defp get_alias_as([opts]) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, parts} -> parts |> List.last()
      atom when is_atom(atom) -> atom
      _ -> nil
    end
  end

  defp get_alias_as(_), do: nil

  defp split_with_clauses(args) do
    Enum.split_while(args, fn
      [{:do, _} | _] -> false
      {:do, _} -> false
      _ -> true
    end)
    |> then(fn
      {clauses, [opts]} when is_list(opts) -> {clauses, opts}
      {clauses, opts} -> {clauses, List.flatten(opts)}
    end)
  end

  defp split_for_clauses(args) do
    Enum.split_while(args, fn
      [{:do, _} | _] -> false
      {:do, _} -> false
      {:into, _} -> false
      {:reduce, _} -> false
      {:uniq, _} -> false
      _ -> true
    end)
    |> then(fn
      {generators, [opts]} when is_list(opts) -> {generators, opts}
      {generators, opts} -> {generators, List.flatten(opts)}
    end)
  end
end
