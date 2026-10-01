java? = System.find_executable("java") != nil
jar? = File.exists?(Outlaw.Config.jar_path())

exclude =
  [:network, :e2e] ++
    if(java? and jar?, do: [], else: [:tlc])

if :tlc in exclude do
  IO.puts("Skipping :tlc tests (need java and `mix outlaw.install`).")
end

ExUnit.start(exclude: exclude)
