import Config

if jar = System.get_env("NOTARY_TLA2TOOLS") do
  config :notary, tla2tools_path: jar
end
