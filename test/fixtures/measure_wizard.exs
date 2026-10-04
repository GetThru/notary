# Catch rates for the buggy wizards over seeds 1..10 at the default 100 runs.
# Run: MIX_ENV=test mix run test/fixtures/measure_wizard.exs
Outlaw.Fixtures.Web.start!()
graph = Outlaw.Fixtures.graph("Wizard")

for {module, expected} <- [
      {Outlaw.Fixtures.WizardEarlyPaySpec, :action_not_enabled},
      {Outlaw.Fixtures.WizardNoPaySpec, :action_not_offered}
    ] do
  caught =
    Enum.count(1..10, fn seed ->
      match?(
        {:error, %Outlaw.Conformance.Failure{kind: ^expected}},
        Outlaw.Conformance.check(module, graph, seed: seed, max_runs: 100)
      )
    end)

  IO.puts("#{inspect(module)}: #{expected} on #{caught}/10 seeds")
end
