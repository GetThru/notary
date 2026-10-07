{
  description = "Notary: TLA+ specs as the contract for Elixir code";

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
        beam = pkgs.beam.packages.erlang_28;

        # The TLA+ tools jar Notary pins (Notary.Config.tla_version/0 and
        # jar_sha256/0). Keep this in sync with lib/notary/config.ex.
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

        # What a project using Notary needs on top of its own Elixir: Java,
        # and the jar (so `mix notary.install` is unnecessary). The variable
        # is exported from shellHook, not set as a mkShell attribute, because
        # `inputsFrom` merges shell hooks but not environment attributes.
        toolsPackages = [ pkgs.jdk21_headless ];
        toolsHook = ''
          export NOTARY_TLA2TOOLS=${tla2tools}/share/java/tla2tools.jar
        '';
      in
      {
        packages.tla2tools = tla2tools;

        # For projects that use Notary: layer onto your own shell with
        # `inputsFrom = [ notary.devShells.${system}.tools ];`.
        devShells.tools = pkgs.mkShell {
          packages = toolsPackages;
          shellHook = toolsHook;
        };

        # For working on Notary itself.
        devShells.default = pkgs.mkShell {
          packages = [
            beam.erlang
            beam.elixir_1_20
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
