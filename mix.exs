defmodule PhoenixKitMediaTimeline.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_media_timeline"

  def project do
    [
      app: :phoenix_kit_media_timeline,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "PhoenixKit Media Timeline",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # PhoenixKit — Storage schemas, Module behaviour, settings, permissions
      {:phoenix_kit, "~> 2.32"},

      # Phoenix Framework
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},

      # Database
      {:ecto_sql, "~> 3.10"},

      # Assets & UI
      {:esbuild, "~> 0.10", only: [:dev], runtime: false},

      # Development Tools
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # The `hex_docs_icon_name:` marker is parsed out of this description by
  # PhoenixKit.KnownPackages to pick the admin catalog icon. Without it the
  # catalog shows the default puzzle piece.
  defp description do
    """
    Scrubbable photo/video timeline for PhoenixKit: a virtualized, \
    date-bucketed media library grid in the spirit of Apple Photos and \
    Google Photos. hex_docs_icon_name: photo
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      # The key must be "GitHub" and the value must contain github.com, or
      # `KnownPackages.github_url_for/2` discards it and falls back to a
      # guessed github.com/BeamLabEU/<package> URL.
      links: %{"GitHub" => @source_url},
      # priv/ carries the prebuilt JS bundle that js_sources/0 declares.
      files: ~w(lib priv mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
  end

  defp aliases do
    [
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild module"],
      "assets.deploy": ["esbuild module --minify"],
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end
end
