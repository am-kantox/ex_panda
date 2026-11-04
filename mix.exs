defmodule ExPanda.MixProject do
  use Mix.Project

  @app :ex_panda
  @version "0.3.0"
  @source_url "https://github.com/am-kantox/ex_panda"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() not in [:dev, :test],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: dialyzer(),
      name: "ExPanda",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        dialyzer: :dev
      ]
    ]
  end

  defp deps do
    [
      # Development and documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false},
      {:benchee_html, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": [
        "format --check-formatted",
        "credo --strict",
        "dialyzer --format short"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, ".dialyzer/dialyzer.plt"},
      plt_add_deps: :app_tree,
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: ".dialyzer",
      list_unused_filters: true,
      ignore_warnings: ".dialyzer/ignore.exs"
    ]
  end

  defp description do
    """
    Full macro expansion for Elixir AST introspection.
    Uses the Elixir compiler's internal expansion engine to produce
    fully expanded ASTs while preserving structural forms.
    """
  end

  defp package do
    [
      name: @app,
      files: ~w(
        lib
        .formatter.exs
        mix.exs
        README.md
        LICENSE
      ),
      licenses: ["MIT"],
      maintainers: ["Aleksei Matiushkin"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/#{@app}"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "stuff/images/logo-48px.png",
      assets: %{"stuff/images" => "assets"},
      extras: ["README.md", "LICENSE"],
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html", "epub"],
      groups_for_modules: [
        "Public API": [ExPanda],
        "Expansion Engine": [
          ExPanda.Walker,
          ExPanda.CompilerExpand
        ],
        "Environment Management": [
          ExPanda.EnvManager
        ]
      ],
      nest_modules_by_prefix: [ExPanda],
      authors: ["Aleksei Matiushkin"],
      canonical: "https://hexdocs.pm/#{@app}"
    ]
  end
end
