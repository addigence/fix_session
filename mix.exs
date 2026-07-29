defmodule FIX.Session.MixProject do
  use Mix.Project

  @version "0.1.2"

  @repo_url "https://github.com/addigence/fix_session"

  def project do
    [
      app: :fix_session,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      docs: docs(),
      description: description(),
      source_url: @repo_url,
      homepage_url: @repo_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl, :public_key]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.10", optional: true},
      {:ekv, "~> 0.4", optional: true},
      {:fix_message, "~> 0.1"},
      {:postgrex, "~> 0.19", optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/addigence/session"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        Stores: [
          FIX.Session.Store,
          FIX.Session.Store.EKV,
          FIX.Session.Store.ETS,
          FIX.Session.Store.Memory,
          FIX.Session.Store.Postgres,
          FIX.Session.Store.Postgres.Migrations
        ],
        Transports: [
          FIX.Session.Transport,
          FIX.Session.Transport.TCP,
          FIX.Session.Transport.TLS
        ]
      ]
    ]
  end

  defp description do
    "An initiator-side FIX session engine for Elixir."
  end
end
