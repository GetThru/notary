# Catch rates for the buggy wizards over seeds 1..10 at the default 100 runs.
# Run: MIX_ENV=test mix run test/fixtures/measure_wizard.exs
Notary.Fixtures.Web.start!()
graph = Notary.Fixtures.graph("Wizard")

for {module, expected} <- [
      {Notary.Fixtures.WizardEarlyPaySpec, :action_not_enabled},
      {Notary.Fixtures.WizardNoPaySpec, :action_not_offered}
    ] do
  caught =
    Enum.count(1..10, fn seed ->
      match?(
        {:error, %Notary.Conformance.Failure{kind: ^expected}},
        Notary.Conformance.check(module, graph, seed: seed, max_runs: 100)
      )
    end)

  IO.puts("#{inspect(module)}: #{expected} on #{caught}/10 seeds")
end
