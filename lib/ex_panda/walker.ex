defmodule ExPanda.Walker do
  @moduledoc """
  Recursive AST walker that expands macros while preserving structural forms.

  The walker traverses the AST top-down, applying these rules:

  1. **Structural forms** (`defmodule`, `def`/`defp`, `defmacro`/`defmacrop`):
     preserved as-is, with their bodies recursively expanded.
  2. **Directives** (`alias`, `import`, `require`): applied to the environment
     for subsequent expansions, preserved in output.
  3. **`use`**: expanded by calling `MACRO-__using__/2` directly, then re-walked.
  4. **Blocks** (`__block__`): each statement walked sequentially, threading the context.
  5. **Expressions**: expanded via `:elixir_expand.expand/3` (or `Macro.expand/2` fallback).
  6. **Failures**: unexpandable nodes are kept with an `@unexpanded` marker prepended.
  ## `defdelegate`

  `defdelegate` is a `Kernel` macro that expands into a `def` whose body calls
  the target module. Because `:elixir_expand.expand/3` only understands
  `def`/`defp` (and `defdelegate` is itself implemented *in terms of* `def`),
  feeding a `defdelegate` node to the compiler's expander raises
  `:elixir_bootstrap.def/2` and the node would be reported as unexpandable.

  The walker therefore expands `defdelegate` itself, mirroring
  `Kernel.Utils.defdelegate_all/3` and `Kernel.Utils.defdelegate_each/2`:

      defdelegate bar(x), to: Baz, as: :quux
      # => def bar(x), do: Baz.quux(x)

  Both the single-function and the list form are supported, and the resulting
  `def` nodes are re-walked so their bodies are expanded like any other.
  """

  alias ExPanda.{CompilerExpand, EnvManager}
  alias ExPanda.Walker.Ctx

  @func_types [:def, :defp, :defmacro, :defmacrop]

  # Forms that must never be treated as operators, even though
  # `Macro.operator?/2` returns true for some of them.
  @special_forms [:fn, :case, :cond, :with, :for, :try, :receive, :quote, :unquote]

  @doc """
  Walk and expand the AST starting from the given environment.

  Returns `{expanded_ast, final_env}`.

  ## Options

    * `:expand_operators` - when `true` (the default) operators are expanded
      like any other macro or special form, e.g. `1 + 2` becomes
      `:erlang.+(1, 2)` and `a && b` becomes a `case`. When `false`,
      operators are preserved verbatim and only their operands are expanded.

  ## Examples

      iex> env = ExPanda.EnvManager.new_env()
      iex> {:ok, ast} = Code.string_to_quoted("1 + 2")
      iex> {expanded, _env} = ExPanda.Walker.walk(ast, env)
      iex> match?({{:., _, [:erlang, :+]}, _, _}, expanded)
      true

      iex> env = ExPanda.EnvManager.new_env()
      iex> {:ok, ast} = Code.string_to_quoted("1 + 2")
      iex> {expanded, _env} = ExPanda.Walker.walk(ast, env, expand_operators: false)
      iex> match?({:+, _, [1, 2]}, expanded)
      true
  """
  @spec walk(Macro.t(), Macro.Env.t(), keyword()) :: {Macro.t(), Macro.Env.t()}
  def walk(ast, env, opts \\ []) do
    {expanded, ctx} = do_walk(ast, Ctx.new(env, opts))
    {expanded, ctx.env}
  end

  # --- Structural Forms ---

  # defmodule Name do ... end
  defp do_walk({:defmodule, meta, [alias_ast, [do: body]]}, ctx) do
    module_name = EnvManager.resolve_module_name(alias_ast, ctx.env)
    module_ctx = %{ctx | env: EnvManager.enter_module(ctx.env, module_name)}
    {expanded_body, _module_ctx} = do_walk(body, module_ctx)
    {{:defmodule, meta, [alias_ast, [do: expanded_body]]}, ctx}
  end

  # defmodule Name do ... end (with other keyword options like @derive, etc.)
  defp do_walk({:defmodule, meta, [alias_ast, opts]}, ctx) when is_list(opts) do
    module_name = EnvManager.resolve_module_name(alias_ast, ctx.env)
    module_ctx = %{ctx | env: EnvManager.enter_module(ctx.env, module_name)}

    expanded_opts =
      Enum.map(opts, fn
        {:do, body} ->
          {expanded_body, _} = do_walk(body, module_ctx)
          {:do, expanded_body}

        other ->
          other
      end)

    {{:defmodule, meta, [alias_ast, expanded_opts]}, ctx}
  end

  # def/defp with guards: def foo(x) when is_integer(x), do: ...
  defp do_walk(
         {func_type, meta, [{:when, when_meta, [{name, sig_meta, args} | guards]}, [do: body]]},
         ctx
       )
       when func_type in @func_types and is_atom(name) do
    params = if is_list(args), do: args, else: []
    arity = length(params)
    param_names = EnvManager.extract_param_names(params)
    func_ctx = %{ctx | env: EnvManager.enter_function(ctx.env, name, arity, param_names)}

    {expanded_body, _} = do_walk(body, func_ctx)

    expanded_guards =
      Enum.map(guards, fn guard ->
        case try_expand_expression(guard, func_ctx.env) do
          {:ok, expanded, _} -> expanded
          {:error, _} -> guard
        end
      end)

    sig = {:when, when_meta, [{name, sig_meta, args} | expanded_guards]}
    {{func_type, meta, [sig, [do: expanded_body]]}, ctx}
  end

  # def/defp with keyword body: def foo(x), do: ...
  defp do_walk({func_type, meta, [{name, sig_meta, args}, [do: body]]}, ctx)
       when func_type in @func_types and is_atom(name) do
    params = if is_list(args), do: args, else: []
    arity = length(params)
    param_names = EnvManager.extract_param_names(params)
    func_ctx = %{ctx | env: EnvManager.enter_function(ctx.env, name, arity, param_names)}

    {expanded_body, _} = do_walk(body, func_ctx)
    {{func_type, meta, [{name, sig_meta, args}, [do: expanded_body]]}, ctx}
  end

  # def/defp with do..end block: def foo(x) do ... end
  defp do_walk({func_type, meta, [{name, sig_meta, args}, opts]}, ctx)
       when func_type in @func_types and is_atom(name) and is_list(opts) do
    params = if is_list(args), do: args, else: []
    arity = length(params)
    param_names = EnvManager.extract_param_names(params)
    func_ctx = %{ctx | env: EnvManager.enter_function(ctx.env, name, arity, param_names)}

    expanded_opts =
      Enum.map(opts, fn
        {:do, body} ->
          {expanded_body, _} = do_walk(body, func_ctx)
          {:do, expanded_body}

        {:rescue, clauses} ->
          expanded_clauses = Enum.map(clauses, &expand_clause(&1, func_ctx))
          {:rescue, expanded_clauses}

        {:catch, clauses} ->
          expanded_clauses = Enum.map(clauses, &expand_clause(&1, func_ctx))
          {:catch, expanded_clauses}

        {:after, body} ->
          {expanded_body, _} = do_walk(body, func_ctx)
          {:after, expanded_body}

        other ->
          other
      end)

    {{func_type, meta, [{name, sig_meta, args}, expanded_opts]}, ctx}
  end

  # defdelegate fun(args), to: Target[, as: :name]
  # defdelegate [fun1(args), fun2(args)], to: Target[, as: :name]
  #
  # Expanded by hand (see @moduledoc): the compiler's expander only knows
  # def/defp, so a defdelegate node reaching :elixir_expand raises
  # `no function clause matching in :elixir_bootstrap.def/2`.
  #
  # The malformed `defdelegate bar(x)` form (no options at all) is matched too:
  # it parses with a `nil` second argument, and without this clause it would
  # silently fall through to the catch-all and be emitted verbatim instead of
  # being flagged as unexpandable.
  defp do_walk({:defdelegate, meta, [funs | rest]} = node, ctx) do
    opts = List.first(rest)

    case expand_defdelegate(meta, funs, opts) do
      {:ok, expanded} -> do_walk(expanded, ctx)
      {:error, reason} -> {mark_unexpanded(node, reason), ctx}
    end
  end

  # --- Directives ---

  # alias Foo.Bar or alias Foo.Bar, as: Baz
  defp do_walk({:alias, meta, [{:__aliases__, _, parts} | opts_rest]}, ctx) do
    module = Module.concat(parts)
    as_name = get_alias_as(opts_rest)
    new_env = EnvManager.apply_alias(ctx.env, module, as_name)
    {{:alias, meta, [{:__aliases__, [], parts} | opts_rest]}, %{ctx | env: new_env}}
  end

  # import Foo or import Foo, only: [...]
  defp do_walk({:import, meta, [target | opts_rest]}, ctx) do
    module = EnvManager.resolve_module_name(target, ctx.env) || target
    import_opts = List.first(opts_rest) || []
    new_env = EnvManager.apply_import(ctx.env, module, import_opts)
    {{:import, meta, [target | opts_rest]}, %{ctx | env: new_env}}
  end

  # require Foo
  defp do_walk({:require, meta, [target | rest]}, ctx) do
    module = EnvManager.resolve_module_name(target, ctx.env) || target

    new_env =
      if is_atom(module),
        do: EnvManager.apply_require(ctx.env, module),
        else: ctx.env

    {{:require, meta, [target | rest]}, %{ctx | env: new_env}}
  end

  # use Foo, opts -- call __using__ macro directly to bypass module table dispatch.
  # The standard Macro.expand path fails inside defmodule because enter_module
  # sets env.module without creating the compiler's ETS module table.
  # Calling MACRO-__using__/2 directly avoids the dispatch check.
  defp do_walk({:use, _meta, args} = node, ctx) do
    with {:ok, module, opts} <- resolve_use_module(args, ctx.env),
         new_env = EnvManager.apply_require(ctx.env, module),
         {:ok, quoted} <- invoke_using_macro(module, opts, new_env) do
      {expanded, final_ctx} = do_walk(quoted, %{ctx | env: new_env})
      result = flatten_block([{:require, [], [module]}, expanded])
      {result, final_ctx}
    else
      {:error, reason} ->
        {mark_unexpanded(node, reason), ctx}
    end
  end

  # defoverridable: keep as-is (compile-time directive, needs module table)
  defp do_walk({:defoverridable, _meta, _args} = node, ctx) do
    {node, ctx}
  end

  # --- Block ---

  # __block__: walk each statement sequentially, threading ctx
  defp do_walk({:__block__, meta, statements}, ctx) when is_list(statements) do
    {expanded_stmts, final_ctx} =
      Enum.map_reduce(statements, ctx, fn stmt, acc_ctx ->
        do_walk(stmt, acc_ctx)
      end)

    {{:__block__, meta, expanded_stmts}, final_ctx}
  end

  # --- Match operator: register bound variables ---

  defp do_walk({:=, meta, [pattern, value]}, ctx) do
    {expanded_value, ctx} = do_walk(value, ctx)
    env = EnvManager.register_pattern_vars(ctx.env, pattern)
    {expanded_pattern, ctx} = do_walk(pattern, %{ctx | env: env})
    {{:=, meta, [expanded_pattern, expanded_value]}, ctx}
  end

  # --- Case / Cond / With: expand children ---

  defp do_walk({:case, meta, [scrutinee, [do: clauses]]}, ctx) do
    {expanded_scrutinee, ctx} = do_walk(scrutinee, ctx)

    expanded_clauses =
      Enum.map(clauses, fn {:->, arrow_meta, [patterns, body]} ->
        clause_ctx = register_clause_vars(ctx, patterns)
        {expanded_body, _} = do_walk(body, clause_ctx)
        {:->, arrow_meta, [patterns, expanded_body]}
      end)

    {{:case, meta, [expanded_scrutinee, [do: expanded_clauses]]}, ctx}
  end

  defp do_walk({:cond, meta, [[do: clauses]]}, ctx) do
    expanded_clauses =
      Enum.map(clauses, fn {:->, arrow_meta, [condition, body]} ->
        {expanded_cond, _} = do_walk(condition, ctx)
        {expanded_body, _} = do_walk(body, ctx)
        {:->, arrow_meta, [expanded_cond, expanded_body]}
      end)

    {{:cond, meta, [[do: expanded_clauses]]}, ctx}
  end

  defp do_walk({:with, meta, args}, ctx) when is_list(args) do
    {clauses, body_opts} = split_with_clauses(args)

    {expanded_clauses, with_ctx} =
      Enum.map_reduce(clauses, ctx, fn
        {:<-, arrow_meta, [pattern, expr]}, acc_ctx ->
          {expanded_expr, acc_ctx} = do_walk(expr, acc_ctx)
          acc_ctx = register_ctx_pattern(acc_ctx, pattern)
          {{:<-, arrow_meta, [pattern, expanded_expr]}, acc_ctx}

        other, acc_ctx ->
          do_walk(other, acc_ctx)
      end)

    expanded_opts =
      Enum.map(body_opts, fn
        {:do, body} ->
          {expanded, _} = do_walk(body, with_ctx)
          {:do, expanded}

        {:else, clauses} ->
          expanded =
            Enum.map(clauses, fn {:->, am, [patterns, body]} ->
              clause_ctx = register_clause_vars(ctx, patterns)
              {expanded_body, _} = do_walk(body, clause_ctx)
              {:->, am, [patterns, expanded_body]}
            end)

          {:else, expanded}

        other ->
          other
      end)

    {{:with, meta, expanded_clauses ++ [expanded_opts]}, ctx}
  end

  # --- Try/Rescue/Catch ---

  defp do_walk({:try, meta, [opts]}, ctx) when is_list(opts) do
    expanded_opts =
      Enum.map(opts, fn
        {:do, body} ->
          {expanded, _} = do_walk(body, ctx)
          {:do, expanded}

        {:rescue, clauses} ->
          {:rescue, Enum.map(clauses, &expand_clause(&1, ctx))}

        {:catch, clauses} ->
          {:catch, Enum.map(clauses, &expand_clause(&1, ctx))}

        {:after, body} ->
          {expanded, _} = do_walk(body, ctx)
          {:after, expanded}

        {:else, clauses} ->
          expanded =
            Enum.map(clauses, fn {:->, am, [patterns, body]} ->
              clause_ctx = register_clause_vars(ctx, patterns)
              {expanded_body, _} = do_walk(body, clause_ctx)
              {:->, am, [patterns, expanded_body]}
            end)

          {:else, expanded}

        other ->
          other
      end)

    {{:try, meta, [expanded_opts]}, ctx}
  end

  # --- For comprehension ---

  defp do_walk({:for, meta, args}, ctx) when is_list(args) do
    {generators, body_opts} = split_for_clauses(args)

    {expanded_gens, for_ctx} =
      Enum.map_reduce(generators, ctx, fn
        {:<-, arrow_meta, [pattern, collection]}, acc_ctx ->
          {expanded_coll, acc_ctx} = do_walk(collection, acc_ctx)
          acc_ctx = register_ctx_pattern(acc_ctx, pattern)
          {{:<-, arrow_meta, [pattern, expanded_coll]}, acc_ctx}

        filter, acc_ctx ->
          do_walk(filter, acc_ctx)
      end)

    expanded_opts =
      Enum.map(body_opts, fn
        {:do, body} ->
          {expanded, _} = do_walk(body, for_ctx)
          {:do, expanded}

        {:into, into} ->
          {expanded, _} = do_walk(into, ctx)
          {:into, expanded}

        {:reduce, init} ->
          {expanded, _} = do_walk(init, ctx)
          {:reduce, expanded}

        other ->
          other
      end)

    {{:for, meta, expanded_gens ++ [expanded_opts]}, ctx}
  end

  # --- fn clauses ---

  defp do_walk({:fn, meta, clauses}, ctx) when is_list(clauses) do
    expanded_clauses =
      Enum.map(clauses, fn {:->, arrow_meta, [params, body]} ->
        param_names = EnvManager.extract_param_names(params)
        clause_ctx = Enum.reduce(param_names, ctx, &register_ctx_var(&2, &1))
        {expanded_body, _} = do_walk(body, clause_ctx)
        {:->, arrow_meta, [params, expanded_body]}
      end)

    {{:fn, meta, expanded_clauses}, ctx}
  end

  # --- Capture operator ---

  # `&` captures must be treated as opaque: the body is a *reference*, not a
  # call. Recursing into it would rewrite `&Enum.map/2` into
  # `&:erlang./(Enum.map(), 2)` and `&(&1 + 1)` into invalid syntax.
  #
  # We still expand macros *inside* the capture (e.g. `&unless(&1, do: &1)`),
  # but never the `/` of a `name/arity` capture nor the bare target of a
  # remote capture.
  defp do_walk({:&, meta, [body]}, ctx) do
    {expanded_body, final_env} = walk_capture(body, ctx)
    {{:&, meta, [expanded_body]}, final_env}
  end

  # --- General expression expansion ---

  # Module attribute: keep as-is (structural)
  defp do_walk({:@, _meta, [{_name, _attr_meta, _}]} = node, ctx) do
    {node, ctx}
  end

  # Two-element tuple (e.g. keyword pair value): walk both elements
  defp do_walk({left, right}, ctx) do
    {expanded_left, ctx} = do_walk(left, ctx)
    {expanded_right, ctx} = do_walk(right, ctx)
    {{expanded_left, expanded_right}, ctx}
  end

  # List: walk each element
  defp do_walk(list, ctx) when is_list(list) do
    Enum.map_reduce(list, ctx, fn elem, acc_ctx ->
      do_walk(elem, acc_ctx)
    end)
  end

  # Literals: pass through
  defp do_walk(literal, ctx)
       when is_atom(literal) or is_number(literal) or is_binary(literal) do
    {literal, ctx}
  end

  # Operators: expanded or preserved depending on `:expand_operators`.
  #
  # Several operators are Kernel *macros* (`<>`, `&&`, `||`, `in`, `|>`,
  # `and`, `or`, `..`), and the rest (`+`, `-`, `*`, `/`, `==`, ...) are
  # special forms that `:elixir_expand` lowers to `:erlang.*` BIF calls.
  #
  # With `expand_operators: true` (the default) they go through the normal
  # expansion path, preserving historical behaviour. With `false` they are
  # kept verbatim and only their operands are expanded, which keeps the
  # output readable and round-trip safe.
  #
  # This clause must precede the generic 3-tuple clause below.
  defp do_walk({op, meta, args} = node, ctx)
       when is_atom(op) and is_list(args) and op not in @special_forms do
    cond do
      not Macro.operator?(op, length(args)) ->
        walk_general(node, ctx)

      ctx.expand_operators ->
        walk_general(node, ctx)

      true ->
        {expanded_args, final_ctx} = Enum.map_reduce(args, ctx, &do_walk/2)
        {{op, meta, expanded_args}, final_ctx}
    end
  end

  # General 3-tuple AST node: try expanding as a macro
  defp do_walk({form, meta, args}, ctx) when is_atom(form) and is_list(args) do
    walk_general({form, meta, args}, ctx)
  end

  # Remote call: {{:., meta, [module, fun]}, call_meta, args}
  defp do_walk({{:., dot_meta, [mod, fun]}, call_meta, args} = node, ctx)
       when is_atom(fun) and is_list(args) do
    case try_expand_expression(node, ctx.env) do
      {:ok, expanded, new_env} ->
        ctx = %{ctx | env: new_env}

        if ast_eq?(expanded, node) do
          {expanded_mod, ctx2} = do_walk(mod, ctx)
          {expanded_args, ctx3} = Enum.map_reduce(args, ctx2, &do_walk/2)
          {{{:., dot_meta, [expanded_mod, fun]}, call_meta, expanded_args}, ctx3}
        else
          do_walk(expanded, ctx)
        end

      {:error, reason} ->
        {mark_unexpanded(node, reason), ctx}
    end
  end

  # Catch-all for other AST forms
  defp do_walk(node, ctx), do: {node, ctx}

  # --- Helpers ---

  defp try_expand_expression(ast, env) do
    CompilerExpand.expand(ast, env)
  end

  # Expand a node as a macro; if it is not a macro, recurse into its children.
  defp walk_general({form, meta, args} = node, ctx) do
    case try_expand_expression(node, ctx.env) do
      {:ok, expanded, new_env} ->
        ctx = %{ctx | env: new_env}

        if ast_eq?(expanded, node) do
          {expanded_args, final_ctx} = Enum.map_reduce(args, ctx, &do_walk/2)
          {{form, meta, expanded_args}, final_ctx}
        else
          do_walk(expanded, ctx)
        end

      {:error, reason} ->
        {mark_unexpanded(node, reason), ctx}
    end
  end

  # Walk the body of a `&` capture without treating references as calls.
  #
  #   * `&Mod.fun/arity` and `&fun/arity` -- left completely untouched
  #   * `&Mod.fun(&1)` / `&(&1 + 1)`     -- operands expanded, `&n` preserved
  defp walk_capture({:/, _meta, [_, arity]} = node, ctx) when is_integer(arity) do
    {node, ctx}
  end

  defp walk_capture({op, meta, args}, ctx) when is_atom(op) and is_list(args) do
    {expanded_args, final_env} = Enum.map_reduce(args, ctx, &do_walk_capture_arg/2)
    {{op, meta, expanded_args}, final_env}
  end

  defp walk_capture(other, ctx), do: do_walk(other, ctx)

  # Capture placeholders `&1`, `&2`, ... are variables, not calls.
  defp do_walk_capture_arg({:&, meta, [n]}, ctx) when is_integer(n), do: {{:&, meta, [n]}, ctx}
  defp do_walk_capture_arg(arg, ctx), do: walk_capture(arg, ctx)

  defp expand_clause({:->, arrow_meta, [patterns, body]}, ctx) do
    clause_ctx = register_clause_vars(ctx, patterns)
    {expanded_body, _} = do_walk(body, clause_ctx)
    {:->, arrow_meta, [patterns, expanded_body]}
  end

  defp expand_clause(other, _ctx), do: other

  # Register the variables bound by clause patterns in the context's env.
  defp register_clause_vars(ctx, patterns) when is_list(patterns) do
    Enum.reduce(patterns, ctx, &register_ctx_pattern(&2, &1))
  end

  defp register_clause_vars(ctx, pattern) do
    register_ctx_pattern(ctx, pattern)
  end

  # Register a single variable in the context's env.
  defp register_ctx_var(ctx, name) do
    %{ctx | env: EnvManager.register_var(ctx.env, name)}
  end

  # Register all variables bound by a pattern in the context's env.
  defp register_ctx_pattern(ctx, pattern) do
    %{ctx | env: EnvManager.register_pattern_vars(ctx.env, pattern)}
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

  defp flatten_block(stmts) do
    flat =
      Enum.flat_map(stmts, fn
        {:__block__, _, inner} when is_list(inner) -> inner
        other -> [other]
      end)

    {:__block__, [], flat}
  end

  # Mirror Kernel.Utils.defdelegate_all/3 + defdelegate_each/2 without
  # requiring a compiled module table.
  defp expand_defdelegate(meta, funs, opts) do
    cond do
      not is_list(opts) ->
        {:error, "defdelegate: expected options, got: #{inspect(opts)}"}

      is_nil(opts[:to]) ->
        {:error, "defdelegate: missing :to option"}

      not is_list(funs) and not is_tuple(funs) ->
        {:error, "defdelegate: invalid function specification"}

      true ->
        target = opts[:to]

        funs
        |> List.wrap()
        |> Enum.map(&delegate_def(&1, target, opts, meta))
        |> case do
          [single] -> {:ok, single}
          many -> {:ok, {:__block__, [], many}}
        end
    end
  rescue
    e -> {:error, "defdelegate: #{Exception.message(e)}"}
  end

  # Kernel.Utils.defdelegate_each/2 normalises both the single-function and
  # the list forms into `{name, args, as, as_args}`, with `args`/`as_args`
  # always lists (`defdelegate bar, to: Baz` yields `args == []`).
  defp delegate_def(fun, target, opts, meta) do
    {name, args, as, as_args} = Kernel.Utils.defdelegate_each(fun, opts)

    {:def, meta, [{name, [], args}, [do: {{:., [], [target, as]}, [], as_args}]]}
  end

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

  # Split `with` arguments into the leading clause list and the trailing
  # keyword options (`do:`/`else:`).
  #
  # The parser already groups the options into a single trailing keyword list,
  # so the common shapes are `[clauses..., [do: ..., else: ...]]`. A flat
  # `[clause, {:do, ...}, {:else, ...}]` shape is also accepted for robustness.
  defp split_with_clauses(args) do
    case split_trailing_opts(args) do
      {clauses, opts} -> {clauses, opts}
    end
  end

  # Compare two AST nodes ignoring metadata (the second element of 3-tuples).
  # :elixir_expand.expand/3 can annotate/normalize metadata (line numbers,
  # variable versions, etc.) without performing any actual macro expansion.
  # A plain == or ^pin comparison sees these metadata-only changes as "expansion"
  # and re-walks, causing an infinite loop on non-macro calls like Task.async_stream.
  defp ast_eq?({form1, _meta1, args1}, {form2, _meta2, args2})
       when is_list(args1) and is_list(args2) do
    ast_eq?(form1, form2) and
      length(args1) == length(args2) and
      args1 |> Enum.zip(args2) |> Enum.all?(fn {a, b} -> ast_eq?(a, b) end)
  end

  # 3-tuple with non-list third element (variable reference, etc.)
  defp ast_eq?({form1, _meta1, ctx1}, {form2, _meta2, ctx2}) do
    ast_eq?(form1, form2) and ast_eq?(ctx1, ctx2)
  end

  defp ast_eq?({l1, r1}, {l2, r2}) do
    ast_eq?(l1, l2) and ast_eq?(r1, r2)
  end

  defp ast_eq?(l1, l2) when is_list(l1) and is_list(l2) do
    length(l1) == length(l2) and
      l1 |> Enum.zip(l2) |> Enum.all?(fn {a, b} -> ast_eq?(a, b) end)
  end

  defp ast_eq?(a, a), do: true
  defp ast_eq?(_, _), do: false

  # Split `for` arguments into the leading generator/filter list and the
  # trailing keyword options (`do:`/`into:`/`reduce:`/`uniq:`).
  #
  # The parser groups the options into a single trailing keyword list, so
  # `for x <- xs, into: %{}, do: ...` arrives as
  # `[{:<-, _, _}, [into: ..., do: ...]]`.
  defp split_for_clauses(args) do
    split_trailing_opts(args)
  end

  # Split a `with`/`for` argument list into `{leading_clauses, keyword_opts}`.
  #
  # Handles both parser-produced shapes:
  #
  #   * grouped   -- `[clause, [do: ..., else: ...]]`
  #   * flat      -- `[clause, {:do, ...}, {:else, ...}]`
  #
  # In both cases the result is `{[clause], [do: ..., else: ...]}`, which is
  # exactly what `Macro.to_string/1` expects: the options must stay a *single*
  # keyword-list element, never spliced into the positional argument list.
  defp split_trailing_opts(args) do
    {leading, trailing} =
      Enum.split_while(args, fn
        [{key, _} | _] when is_atom(key) -> false
        {key, _} when is_atom(key) -> false
        _ -> true
      end)

    {leading, List.flatten(trailing)}
  end
end
