{
  description = "Outlaw: TLA+ specs as the contract for Elixir code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        beam = pkgs.beam.packages.erlang_27;

        # The TLA+ tools jar Outlaw pins (Outlaw.Config.tla_version/0 and
        # jar_sha256/0). Keep this in sync with lib/outlaw/config.ex.
        tla2tools = pkgs.stdenvNoCC.mkDerivation rec {
          pname = "tla2tools";
          version = "1.7.4";
          src = pkgs.fetchurl {
            url = "https://github.com/tlaplus/tlaplus/releases/download/v${version}/tla2tools.jar";
            hash = "sha256-k2omIGHJFGlN/WaaVDviRXPEXVqg/yCouWsj0B4FDog=";
          };
          dontUnpack = true;
          installPhase = ''
            install -Dm644 $src $out/share/java/tla2tools.jar
          '';
        };

        # What a project using Outlaw needs on top of its own Elixir: Java,
        # and the jar (so `mix outlaw.install` is unnecessary). The variable
        # is exported from shellHook, not set as a mkShell attribute, because
        # `inputsFrom` merges shell hooks but not environment attributes.
        toolsPackages = [ pkgs.jdk21_headless ];
        toolsHook = ''
          export OUTLAW_TLA2TOOLS=${tla2tools}/share/java/tla2tools.jar
        '';
      in
      {
        packages.tla2tools = tla2tools;

        # For projects that use Outlaw: layer onto your own shell with
        # `inputsFrom = [ outlaw.devShells.${system}.tools ];`.
        devShells.tools = pkgs.mkShell {
          packages = toolsPackages;
          shellHook = toolsHook;
        };

        # For working on Outlaw itself.
        devShells.default = pkgs.mkShell {
          packages = [
            beam.erlang
            beam.elixir_1_19
          ]
          ++ toolsPackages;
          shellHook = toolsHook + ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export ERL_AFLAGS="-kernel shell_history enabled"
          '';
        };
      }
    );
}
