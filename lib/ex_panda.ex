defmodule ExPanda do
  @moduledoc """
  Full macro expansion for Elixir AST introspection.

  ExPanda takes Elixir source code (or a pre-parsed AST) and produces an AST
  where all macros have been expanded to their underlying forms, while preserving
  structural constructs (`defmodule`, `def`/`defp`) as-is.

  It uses the Elixir compiler's internal `:elixir_expand.expand/3` as the
  primary expansion engine, with a fallback to `Macro.expand/2` for environments
  where the internal API is unavailable.

  ## Quick Start

      # Expand a source code string
      {:ok, expanded} = ExPanda.expand_string("unless true, do: :never")
      # => {:case, _, [true, [do: [...]]]}

      # Expand a file
      {:ok, expanded} = ExPanda.expand_file("lib/my_module.ex")

      # Expand a pre-parsed AST
      {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      {:ok, expanded} = ExPanda.expand(ast)
      # => {{:., _, [String.Chars, :to_string]}, _, [1]}

  ## Structural Preservation

  `defmodule` and `def`/`defp` forms are kept intact in the output.
  Only their bodies are expanded:

      {:ok, expanded} = ExPanda.expand_string(\"\"\"\n      defmodule Foo do\n        def bar(x), do: unless(x, do: :fallback)\n      end\n      \"\"\")
      # defmodule is preserved, but `unless` inside bar's body is expanded to `case`

  ## Unexpandable Macros

  When a macro cannot be expanded (e.g., the target module is not loaded),
  the original node is kept with an `@unexpanded` error marker prepended:

      {:__block__, [], [
        {:@, [], [{:unexpanded, [], ["use/1: ..."]}]},
        {:use, [], [{:__aliases__, [], [:SomeUnloadedLib]}]}
      ]}
  """

  alias ExPanda.{EnvManager, Walker}

  @doc """
  Expand all macros in a source code string.

  ## Options

    * `:env` - Custom `Macro.Env` to use as the base environment.
      Defaults to a fresh environment from `:elixir_env.new()`.
    * `:file` - File path to set in the environment (for error messages).
      Defaults to `"nofile"`.
    * `:preserve_lines` - Whether to preserve line/column metadata in parsed AST.
      Defaults to `true`.

  ## Examples

      iex> {:ok, expanded} = ExPanda.expand_string("unless true, do: :never")
      iex> match?({:case, _, _}, expanded)
      true
  """
  @spec expand_string(String.t(), keyword()) :: {:ok, Macro.t()} | {:error, term()}
  def expand_string(source, opts \\ []) when is_binary(source) do
    parse_opts = if Keyword.get(opts, :preserve_lines, true), do: [columns: true], else: []

    case Code.string_to_quoted(source, parse_opts) do
      {:ok, ast} ->
        opts =
          Keyword.update(opts, :file, "nofile", fn
            <<_::utf8, _::binary>> = file -> file
            _ -> "nofile"
          end)

        expand(ast, opts)

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line, 0), else: 0
        {:error, "Parse error at line #{line}: #{inspect(message)}#{inspect(token)}"}
    end
  end

  @doc """
  Expand all macros in an Elixir source file.

  ## Options

  Same as `expand_string/2`. The `:file` option defaults to the given path.

  ## Examples

      {:ok, expanded} = ExPanda.expand_file("lib/my_module.ex")
  """
  @spec expand_file(String.t(), keyword()) :: {:ok, Macro.t()} | {:error, term()}
  def expand_file(path, opts \\ []) when is_binary(path) do
    case File.read(path) do
      {:ok, source} ->
        opts = Keyword.put_new(opts, :file, path)
        expand_string(source, opts)

      {:error, reason} ->
        {:error, "Cannot read file #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Expand all macros in a pre-parsed Elixir AST.

  ## Options

    * `:env` - Custom `Macro.Env` to use as the base environment.
    * `:file` - File path to set in the environment.

  ## Examples

      iex> {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      iex> {:ok, expanded} = ExPanda.expand(ast)
      iex> match?({{:., _, [String.Chars, :to_string]}, _, [1]}, expanded)
      true
  """
  @spec expand(Macro.t(), keyword()) :: {:ok, Macro.t()} | {:error, term()}
  def expand(ast, opts \\ []) do
    {expanded, _env} = Walker.walk(ast, build_env(opts))
    {:ok, expanded}
  rescue
    e -> {:error, "Expansion failed: #{Exception.message(e)}"}
  end

  @doc """
  Expand all macros in a pre-parsed AST with an explicit environment.

  Returns both the expanded AST and the final environment state.

  ## Examples

      iex> env = ExPanda.EnvManager.new_env()
      iex> {:ok, ast} = Code.string_to_quoted("unless true, do: :never")
      iex> {:ok, expanded, _final_env} = ExPanda.expand(ast, env, [])
      iex> match?({:case, _, _}, expanded)
      true
  """
  @spec expand(Macro.t(), Macro.Env.t(), keyword()) ::
          {:ok, Macro.t(), Macro.Env.t()} | {:error, term()}
  def expand(ast, %Macro.Env{} = env, _opts) do
    {expanded, final_env} = Walker.walk(ast, env)
    {:ok, expanded, final_env}
  rescue
    e -> {:error, "Expansion failed: #{Exception.message(e)}"}
  end

  @doc """
  Expand all macros and return formatted Elixir code.

  Accepts either a source code string or a pre-parsed AST.
  The result is formatted with `Code.format_string!/2`, preserving
  whitespace in docstrings.

  ## Options

  When given a string, accepts the same options as `expand_string/2`.
  When given an AST, accepts the same options as `expand/2`.
  Additionally:

    * `:format` - Options passed to `Code.format_string!/2`.
      Defaults to `[]`.

  ## Examples

      iex> {:ok, code} = ExPanda.expand_to_string("unless true, do: :never")
      iex> code =~ "case"
      true

      iex> {:ok, ast} = Code.string_to_quoted("1 |> to_string()")
      iex> {:ok, code} = ExPanda.expand_to_string(ast)
      iex> code =~ "String.Chars.to_string"
      true
  """
  @spec expand_to_string(String.t() | Macro.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def expand_to_string(input, opts \\ [])

  def expand_to_string(source, opts) when is_binary(source) do
    {format_opts, expand_opts} = Keyword.pop(opts, :format, [])

    with {:ok, ast} <- expand_string(source, expand_opts) do
      ast_to_formatted_string(ast, format_opts)
    end
  rescue
    e -> {:error, "Formatting failed: #{Exception.message(e)}"}
  end

  def expand_to_string(ast, opts) do
    {format_opts, expand_opts} = Keyword.pop(opts, :format, [])

    with {:ok, expanded} <- expand(ast, expand_opts) do
      ast_to_formatted_string(expanded, format_opts)
    end
  rescue
    e -> {:error, "Formatting failed: #{Exception.message(e)}"}
  end

  # --- Private ---

  defp ast_to_formatted_string(ast, format_opts) do
    code =
      ast
      |> Macro.to_string()
      |> Code.format_string!(format_opts)
      |> IO.iodata_to_binary()

    {:ok, code}
  end

  defp build_env(opts) do
    env = with nil <- Keyword.get(opts, :env), do: EnvManager.new_env()

    case Keyword.get(opts, :file) do
      nil -> env
      file -> EnvManager.put_file(env, file)
    end
  end
end
