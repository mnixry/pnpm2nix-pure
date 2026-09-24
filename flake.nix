{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      {
        config,
        lib,
        withSystem,
        ...
      }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        systems = [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-linux"
        ];

        flake = {
          overlays.default = _: prev: {
            inherit (prev.callPackage ./nix/derivation.nix { }) mkPnpmPackage mkPnpmNodeModules;
          };
          lib = lib.genAttrs config.systems (
            system: withSystem system ({ pkgs, ... }: { inherit (pkgs) mkPnpmPackage mkPnpmNodeModules; })
          );
        };

        perSystem =
          {
            config,
            pkgs,
            system,
            ...
          }:
          let
            tools = pkgs.callPackage ./nix/tools.nix { };
            regenerateFixtures = pkgs.writeShellApplication {
              name = "regenerate-fixtures";
              runtimeInputs = [
                pkgs.nodejs_24
                pkgs.git
                pkgs.gnutar
                pkgs.gzip
              ];
              text = ''
                exec node ${tools}/lib/tests/generate.ts \
                  --pnpm10 ${pkgs.pnpm_10}/bin/pnpm \
                  --pnpm11 ${pkgs.pnpm_11}/bin/pnpm \
                  --pnpm12 ${pkgs.pnpm_12}/bin/pnpm \
                  "$@"
              '';
            };
          in
          {
            _module.args.pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            };

            checks = import ./tests { inherit pkgs; } // import ./tests/integration.nix { inherit pkgs; };

            packages.tools = tools;
            packages.nodeModules = tools.nodeModules;

            apps.regenerate-fixtures = {
              type = "app";
              program = lib.getExe regenerateFixtures;
              meta.description = "Regenerate fixtures with pinned pnpm 10, 11, and 12";
            };

            treefmt = {
              projectRootFile = "flake.nix";
              settings.global.excludes = [
                "tests/fixtures/**"
                "pnpm-lock.yaml"
                "**/pnpm-lock.yaml"
                "**/provenance.json"
                "**/*.tgz"
              ];
              programs.nixfmt.enable = true;
              programs.nixf-diagnose.enable = true;
              programs.yamlfmt.enable = true;
              programs.actionlint.enable = true;
              programs.oxfmt = {
                enable = true;
                package = tools;
                includes = [
                  "tests/generate.ts"
                  "package.json"
                  "tsconfig.json"
                ];
              };
              settings.formatter.oxlint = {
                command = "${tools}/bin/oxlint";
                includes = [ "tests/generate.ts" ];
                options = [ "--deny-warnings" ];
              };
            };

            devShells.default = pkgs.mkShell {
              inputsFrom = [ config.treefmt.build.devShell ];
              packages = [
                pkgs.nodejs_24
                pkgs.pnpm
                pkgs.git
                regenerateFixtures
              ];
            };
          };
      }
    );
}
