defmodule FIX.Session.MixProject do
  use Mix.Project

  def project do
    [
      app: :fix_session,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

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
      {:fix_message, "~> 0.1"}
    ]
  end
end
