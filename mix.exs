defmodule Outlaw.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :outlaw,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_ignore_filters: [~r{^test/fixtures/}],
      description:
        "TLA+ specifications as the contract between humans and LLMs for Elixir projects.",
      name: "Outlaw",
      docs: docs()
    ]
  end

  def cli, do: [preferred_envs: ["outlaw.test": :test, "outlaw.verify": :test]]

  def application do
    [extra_applications: [:logger, :eex, :mix, :inets, :ssl, :public_key, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:stream_data, "~> 1.1"},
      {:pentiment, "~> 0.2"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "guides/getting-started.md"],
      groups_for_extras: [Guides: ~r{^guides/}]
    ]
  end
end
