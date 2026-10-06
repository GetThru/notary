defmodule Notary.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :notary,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_ignore_filters: [~r{^test/fixtures/}],
      description:
        "TLA+ specifications as the contract between humans and LLMs for Elixir projects.",
      name: "Notary",
      docs: docs()
    ]
  end

  def cli, do: [preferred_envs: ["notary.test": :test, "notary.verify": :test]]

  def application do
    [extra_applications: [:logger, :eex, :mix, :inets, :ssl, :public_key, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:stream_data, "~> 1.1"},
      {:pentiment, "~> 0.2.1"},
      {:phoenix_live_view, "~> 1.2", optional: true},
      {:lazy_html, "~> 0.1", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/rate-limiter.md",
        "guides/liveview.md"
      ],
      groups_for_extras: [Guides: ~r{^guides/}],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  # Renders ```mermaid code blocks in the HTML docs as diagrams.
  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@12.1.0/dist/mermaid.min.js"></script>
    <script>
      let mermaidInitialized = false;
      window.addEventListener("exdoc:loaded", () => {
        if (!mermaidInitialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          mermaidInitialized = true;
        }
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphEl = document.createElement("div");
          mermaid.render("mermaid-graph-" + id++, codeEl.textContent).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""
end
