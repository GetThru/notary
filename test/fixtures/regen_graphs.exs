# Regenerates test/fixtures/graphs/*.dot from test/fixtures/specs with TLC.
# Run: nix develop -c mix run test/fixtures/regen_graphs.exs
for name <- ~w(Counter Bank Workflow Async Wizard) do
  {:ok, spec} = Notary.Spec.fetch(name, "test/fixtures/specs")
  dest = Path.expand("test/fixtures/graphs/#{name}.dot")
  File.mkdir_p!(Path.dirname(dest))
  {:ok, stats} = Notary.TLC.dump(spec, dest)
  IO.puts("#{name}: #{stats.distinct_states} states -> #{dest}")
end
