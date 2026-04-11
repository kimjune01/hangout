defmodule Hangout.MixProject do
  use Mix.Project

  def project do
    [
      app: :hangout,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Hangout.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:ranch, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      {:heroicons, "~> 0.5"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev}
    ]
  end
end
