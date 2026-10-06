defmodule Notary.ConfigTest do
  use ExUnit.Case, async: true

  alias Notary.Config

  describe "jar pinning constants" do
    test "jar_url uses the pinned version" do
      assert Config.jar_url() ==
               "https://github.com/tlaplus/tlaplus/releases/download/v#{Config.tla_version()}/tla2tools.jar"
    end

    test "jar_sha256/0 matches the nix flake's pinned hash and version" do
      # flake.nix duplicates the version and sha ("keep in sync" comment);
      # drift would make `mix notary.install` and `nix build` disagree. Read
      # the flake and assert the constants match Config's.
      flake = Path.join(File.cwd!(), "flake.nix")

      if File.exists?(flake) do
        text = File.read!(flake)
        version = Config.tla_version()

        # Nix's sha256 base32 (SRI hash) can't be compared directly with our
        # hex digest; instead fetch nothing -- rebuild the sha256 the same way
        # nix's hash computation does is out of scope. The practical sync
        # check: the flake's version string matches ours, and the flake's
        # fetchurl URL matches Config.jar_url/0's.
        assert text =~ ~s(version = "#{version}";)

        assert text =~
                 ~s(url = "https://github.com/tlaplus/tlaplus/releases/download/v${version}/tla2tools.jar";)

        # The SRI hash in the flake must decode to the same sha256 hex that
        # Config pins. Base32-decode the nix hash and compare digests.
        [_, sri] = Regex.run(~r/hash = "sha256-([A-Za-z0-9+\/=]+)";/, text)
        assert Base.decode64!(sri) |> Base.encode16(case: :lower) == Config.jar_sha256()
      end
    end
  end
end
