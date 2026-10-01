import Config

if jar = System.get_env("OUTLAW_TLA2TOOLS") do
  config :outlaw, tla2tools_path: jar
end
