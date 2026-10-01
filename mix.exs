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
      description:
        "TLA+ specifications as the contract between humans and LLMs for Elixir projects."
    ]
  end

  def application do
    [extra_applications: [:logger, :eex, :mix, :inets, :ssl, :public_key, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [{:stream_data, "~> 1.1"}]
  end
end
