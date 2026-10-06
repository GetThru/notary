defmodule SampleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample_app,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [{:notary, path: System.get_env("NOTARY_PATH", "../.."), only: [:dev, :test]}]
    ]
  end

  def cli, do: [preferred_envs: ["notary.test": :test, "notary.verify": :test]]

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/notary"]
  defp elixirc_paths(_), do: ["lib"]
end
