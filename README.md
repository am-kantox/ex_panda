<img src="https://raw.githubusercontent.com/am-kantox/ex_panda/v0.2.0/stuff/images/logo-500px-transparent.png" alt="ExPanda" width="240" align="right">

# ExPanda

[![CI](https://github.com/am-kantox/ex_panda/actions/workflows/ci.yml/badge.svg)](https://github.com/am-kantox/ex_panda/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_panda.svg)](https://hex.pm/packages/ex_panda)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/ex_panda)

**Full macro expansion for Elixir AST introspection.**

ExPanda takes Elixir source code (or a pre-parsed AST) and produces an AST
where all macros have been expanded to their underlying forms, while preserving
structural constructs (`defmodule`, `def`/`defp`) as-is.

## The Problem

`Code.string_to_quoted/1` returns the **surface-level** AST. Macros such as
`unless`, `|>`, `use GenServer`, Ecto's `schema`, and Phoenix macros all remain
as opaque calls:

```elixir
{:ok, ast} = Code.string_to_quoted("1 |> to_string() |> String.upcase()")
# => {:|>, _, [{:|>, _, [1, {:to_string, _, []}]}, ...]}
```

For tools that need to reason about the actual control flow, data flow, or
function call graph, this is insufficient. ExPanda resolves all macros to their
expanded forms:

```elixir
{:ok, expanded} = ExPanda.expand_string("1 |> to_string() |> String.upcase()")
# => {{:., _, [String, :upcase]}, _, [{{:., _, [String.Chars, :to_string]}, _, [1]}]}
```

## Installation

Add `ex_panda` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_panda, "~> 0.1"}
  ]
end
```

## Usage

### Expanding a Source String

```elixir
{:ok, expanded} = ExPanda.expand_string("unless true, do: :never")
# `unless` is expanded to `case`:
# {:case, _, [true, [do: [{:->, _, [[false], :never]}, {:->, _, [[true], nil]}]]]}
```

### Expanding a File

```elixir
{:ok, expanded} = ExPanda.expand_file("lib/my_module.ex")
```

### Expanding a Pre-parsed AST

```elixir
{:ok, ast} = Code.string_to_quoted("1 |> to_string()")
{:ok, expanded} = ExPanda.expand(ast)
# => {{:., _, [String.Chars, :to_string]}, _, [1]}
```

### Expanding to Formatted Source Code

To get back formatted Elixir source instead of AST, use `expand_to_string/2`.
It accepts both source strings and pre-parsed AST:

```elixir
{:ok, code} = ExPanda.expand_to_string("1 |> to_string() |> String.upcase()")
# => "String.upcase(String.Chars.to_string(1))"

{:ok, ast} = Code.string_to_quoted("unless true, do: :never")
{:ok, code} = ExPanda.expand_to_string(ast)
# => "case true do\n  x when x in [false, nil] ->\n    :never\n  _ ->\n    nil\nend"
```

### Expanding with a Custom Environment

When running inside a Mix project where all dependencies are compiled,
you can pass `__ENV__` so that library macros (`use GenServer`,
Ecto schemas, Phoenix macros) are also expanded:

```elixir
{:ok, expanded, _final_env} = ExPanda.expand(ast, __ENV__, [])
```

## `use` Expansion

`use GenServer` and similar `use` directives are expanded by calling the
target module's `MACRO-__using__/2` function directly, bypassing the
standard macro dispatch that requires a compile-time module table.
This means `use` works inside `defmodule` even without full compilation:

```elixir
{:ok, expanded} = ExPanda.expand_string("""
defmodule MyServer do
  use GenServer
end
""")

# The output contains the expanded @behaviour, def child_spec, etc.
# with no @unexpanded markers.
```

## Structural Preservation

`defmodule` and `def`/`defp`/`defmacro`/`defmacrop` forms are kept intact in the
output. Only their bodies are expanded:

```elixir
{:ok, expanded} = ExPanda.expand_string("""
defmodule Foo do
  def bar(x), do: unless(x, do: :fallback)
end
""")

# Output preserves defmodule + def structure:
# {:defmodule, _, [{:__aliases__, _, [:Foo]},
#   [do: {:def, _, [{:bar, _, _}, [do: {:case, _, _}]]}]]}
```

Directives (`alias`, `import`, `require`) are also preserved in the output
and applied to the environment so that subsequent macro expansions resolve
correctly.

## Unexpandable Macros

When a macro cannot be expanded (e.g., the target module is not loaded in the
current runtime), the original node is kept with an `@unexpanded` error marker
prepended:

```elixir
{:__block__, [], [
  {:@, [], [{:unexpanded, [], ["use/1: function NonExistentModule.__using__/1 is undefined"]}]},
  {:use, [], [{:__aliases__, [], [:NonExistentModule]}]}
]}
```

This makes it straightforward to detect which parts of the AST could not be
fully resolved, without crashing the expansion process.

## How It Works

ExPanda combines two expansion strategies:

1. **`:elixir_expand.expand/3`** (primary engine) -- the Elixir compiler's
   internal expansion function. It recursively expands all nested macros,
   resolves aliases, and handles special forms. Used for expression-level
   expansion within function bodies.

2. **`Macro.expand/2`** (fallback) -- the public API. Used as a fallback when
   the internal engine fails (e.g., undefined variables).

3. **Direct `MACRO-__using__/2` call** -- for `use` directives, the target
   module's `__using__` macro is called directly, bypassing the compiler
   dispatch that requires an ETS module table. This enables `use GenServer`
   and similar expansions inside `defmodule` without full compilation.

The Walker module implements a recursive top-down traversal that threads a
`Macro.Env` struct through the AST, updating it as directives are encountered:

- `alias Foo.Bar` -- updates `env.aliases`
- `import Foo` -- loads functions/macros into `env.functions`/`env.macros`
- `require Foo` -- adds to `env.requires`
- `defmodule` -- creates a child scope with the module context
- `def`/`defp` -- registers parameters as variables in the env

## Integration with Metastatic

`ExPanda` serves as the foundation for [Metastatic](https://github.com/Oeditus/metastatic)’s
Elixir adapter, enabling accurate cross-language code analysis on real, fully-resolved ASTs.

The expanded AST produced by ExPanda feeds directly into
`Metastatic.Adapters.Elixir.ToMeta.transform/1`, since it produces standard
Elixir AST (`{form, meta, args}` tuples) -- just with all macros resolved.
This gives Metastatic a true representation of the code's semantics rather
than its surface syntax.

## Development

```bash
# Run tests
mix test

# Run with coverage
MIX_ENV=test mix coveralls

# Code quality
mix quality

# Generate documentation
mix docs
```

## Technical Risks

- `:elixir_expand` stability — private API, may change between versions.
  Mitigated by version-guarded calls and `Macro.expand/2` fallback
- Side effects during expansion — some macros register state during
  compilation (e.g., Ecto schema fields).
  Without full compilation, expansion may be incomplete for these macros
- Variable binding — `:elixir_expand` raises on undefined vars.
  Mitigated by pre-registering function params and pattern-match
  bindings in the env

## License

Copyright 2026 Aleksei Matiushkin

This project is licensed under the MIT License.
See the [LICENSE](LICENSE) file for details.

