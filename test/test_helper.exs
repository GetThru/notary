java? = System.find_executable("java") != nil
jar? = File.exists?(Notary.Config.jar_path())

exclude =
  [:network, :e2e] ++
    if(java? and jar?, do: [], else: [:tlc])

if :tlc in exclude do
  IO.puts("Skipping :tlc tests (need java and `mix notary.install`).")
end

Notary.Fixtures.Web.start!()

ExUnit.start(exclude: exclude)
