defmodule FIX.Session.MixProject do
  use Mix.Project
  @version "0.1.1"

  @repo_url "https://github.com/addigence/fix_session"

  def project do
    [
      app: :fix_session,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
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
      extra_applications: [:logger],
      mod: {FIX.Session.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fix_message, "~> 0.1"},
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

  defp description do
    "An initiator-side FIX session engine for Elixir."
  end
end
