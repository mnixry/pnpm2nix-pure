{
  pkgs,
  lockfileResolver ? "regex",
}:
let
  inherit (pkgs) lib;
  registry = "file://${./integration/registry}";
  # An accidental development fetch must fail even if it is later discarded.
  productionRegistry = "file://${
    builtins.path {
      path = ./integration/registry;
      name = "production-registry";
      filter = path: _: baseNameOf path != "fixture-dev";
    }
  }";
  fixture =
    name: directory: expected: attrs:
    let
      package = pkgs.mkPnpmPackage (
        {
          inherit registry lockfileResolver;
          name = "pnpm2nix-${name}";
          src = ./integration + "/${directory}";
        }
        // attrs
        // {
          preBuild = ''
            ${
              if attrs.installInPlace or false || attrs.copyNodeModules or false then
                ''
                  test ! -L node_modules
                  printf 'writable\n' > node_modules/copy-is-writable
                ''
              else
                ''
                  test -L node_modules
                ''
            }
            ${attrs.preBuild or ""}
          '';
        }
      );
      actual = pkgs.runCommand "${name}-result.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
        jq -cS . ${package}/result.json > "$out"
      '';
    in
    pkgs.testers.testEqualContents {
      assertion = name;
      inherit actual;
      expected = pkgs.writeText "${name}-expected.json" (builtins.toJSON expected + "\n");
      checkMetadata = false;
    };
  workspaceSources = directory: [
    {
      name = "pnpm-workspace.yaml";
      value = ./integration + "/${directory}/pnpm-workspace.yaml";
    }
  ];
  native =
    name: allow: inPlace:
    let
      workspace =
        if allow then
          ./integration/native/pnpm-workspace.yaml
        else
          ./integration/native/pnpm-workspace-deny.yaml;
    in
    fixture name "native"
      {
        value = if allow then 42 else null;
        source = true;
        headers = true;
      }
      {
        installInPlace = inPlace;
        FIXTURE_BUILD_ALLOWED = if allow then "1" else "0";
        postPatch = "cp ${workspace} pnpm-workspace.yaml";
        extraNodeModuleSources = [
          {
            name = "pnpm-workspace.yaml";
            value = workspace;
          }
        ];
        postBuild = lib.optionalString (!allow) "test ! -e node_modules/fixture-native/addon.node";
      };
  absentDev = ''
    test ! -e node_modules/fixture-dev
    test ! -e node_modules/.pnpm/fixture-dev@1.0.0
  '';
  standaloneNodeModules = pkgs.mkPnpmNodeModules {
    inherit registry lockfileResolver;
    name = "pnpm2nix-standalone-node-modules";
    src = ./integration/basic;
    postInstall = ''
      test ! -e "$out/build.cjs"
      test ! -e "$out/dist"
      test "$(node -p "require('$out/node_modules/fixture-value')")" = 41
    '';
  };
  overriddenNodeModules = standaloneNodeModules.overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.jq ];
    FIXTURE_VALUE = "51";
    postInstall = old.postInstall + ''
      jq -nr '"module.exports = " + env.FIXTURE_VALUE + ";"' > "$out/node_modules/fixture-value/index.cjs"
    '';
  });
in
{
  integration-standalone-node-modules = standaloneNodeModules;
  integration-overridden-node-modules =
    fixture "overridden-node-modules" "basic"
      {
        value = 51;
        development = "development";
      }
      {
        nodeModules = overriddenNodeModules;
      };
  integration-overridden-workspace = fixture "overridden-workspace" "workspace" { value = 62; } {
    installInPlace = true;
    nodeModules =
      (pkgs.mkPnpmNodeModules {
        inherit registry lockfileResolver;
        src = ./integration/workspace;
        installInPlace = true;
      }).overrideAttrs
        {
          postBuild = ''
            printf '%s\n' 'module.exports = require("fixture-value") + 20;' > packages/helper/index.cjs
          '';
        };
  };
  integration-empty = fixture "empty" "empty" { empty = true; } { };
  integration-registry = fixture "registry" "basic" {
    value = 41;
    development = "development";
  } { };
  integration-binary = fixture "binary" "binary" { value = 42; } {
    registry = "https://registry.npmjs.org";
    extraNodeModuleSources = workspaceSources "binary";
    postBuild = ''test "$(node_modules/.bin/esbuild --version)" = "0.27.2"'';
  };
  integration-production =
    fixture "production" "basic"
      {
        value = 41;
        development = null;
      }
      {
        noDevDependencies = true;
        FIXTURE_PRODUCTION = "1";
        registry = productionRegistry;
        postBuild = absentDev;
      };
  integration-production-peer-context =
    fixture "production-peer-context" "production-peers" { value = 41; }
      {
        noDevDependencies = true;
        registry = productionRegistry;
        extraNodeModuleSources = workspaceSources "production-peers" ++ [
          {
            name = "packages";
            value = ./integration/production-peers/packages;
          }
        ];
        postBuild = absentDev + ''
          for entry in node_modules/.pnpm/fixture-peer*; do
            case "$entry" in *fixture-dev*) exit 1 ;; esac
          done
        '';
      };
  integration-copy-node-modules =
    fixture "copy-node-modules" "basic"
      {
        value = 41;
        development = "development";
      }
      {
        copyNodeModules = true;
      };
  integration-config-plugin =
    fixture "config-plugin" "config-plugin"
      {
        value = 41;
        marker = "plugin executed\n";
      }
      {
        extraNodeModuleSources = workspaceSources "config-plugin";
        preBuild = ''
          cmp ${./integration/config-plugin/pnpm-lock.yaml} pnpm-lock.yaml
          export PNPM2NIX_PLUGIN_MARKER="$NIX_BUILD_TOP/plugin-hook"
          test ! -e "$PNPM2NIX_PLUGIN_MARKER"
          cp -R node_modules/ before-node-modules
        '';
        postBuild = ''
          cmp ${./integration/config-plugin/pnpm-lock.yaml} pnpm-lock.yaml
          diff -r --no-dereference before-node-modules node_modules/
        '';
      };
  integration-workspace-isolated = fixture "workspace-isolated" "workspace" { value = 42; } {
    extraNodeModuleSources = workspaceSources "workspace" ++ [
      {
        name = "packages";
        value = ./integration/workspace/packages;
      }
    ];
  };
  integration-workspace-in-place = fixture "workspace-in-place" "workspace" { value = 43; } {
    installInPlace = true;
    postPatch = ''printf '%s\n' 'module.exports += 1;' >> packages/helper/index.cjs'';
    postBuild = ''printf 'workspace writable\n' > packages/library/built-here'';
  };
  integration-workspace-copy = fixture "workspace-copy" "workspace" { value = 52; } {
    copyNodeModules = true;
    postPatch = ''
      printf '%s\n' 'module.exports = require("fixture-value") + 10;' > packages/helper/index.cjs
    '';
    extraNodeModuleSources = workspaceSources "workspace" ++ [
      {
        name = "packages";
        value = ./integration/workspace/packages;
      }
    ];
  };
  integration-native-isolated = native "native-isolated" true false;
  integration-native-in-place = native "native-in-place" true true;
  integration-denied-build-script = native "denied-build-script" false false;
  integration-patched = fixture "patched" "patched" { value = 42; } {
    extraNodeModuleSources = workspaceSources "patched" ++ [
      {
        name = "patches";
        value = ./integration/patched/patches;
      }
    ];
  };
  integration-tarball = fixture "tarball" "tarball" {
    number = true;
    nonNumber = false;
  } { };
  integration-git = fixture "git" "git" {
    number = true;
    nonNumber = false;
  } { };
}
// lib.listToAttrs (
  lib.concatMap
    (major: [
      (lib.nameValuePair "integration-pnpm${major}-registry" (
        fixture "pnpm${major}-registry" "basic"
          {
            value = 41;
            development = "development";
          }
          {
            pnpmLockYaml = ./fixtures + "/pnpm-${major}/basic/pnpm-lock.yaml";
          }
      ))
      (lib.nameValuePair "integration-pnpm${major}-workspace" (
        fixture "pnpm${major}-workspace" "workspace" { value = 42; } {
          pnpmLockYaml = ./fixtures + "/pnpm-${major}/workspace/pnpm-lock.yaml";
          extraNodeModuleSources = workspaceSources "workspace" ++ [
            {
              name = "packages";
              value = ./integration/workspace/packages;
            }
          ];
        }
      ))
      (lib.nameValuePair "integration-pnpm${major}-patched" (
        fixture "pnpm${major}-patched" "patched" { value = 42; } {
          pnpmLockYaml = ./fixtures + "/pnpm-${major}/patched/pnpm-lock.yaml";
          extraNodeModuleSources = workspaceSources "patched" ++ [
            {
              name = "patches";
              value = ./integration/patched/patches;
            }
          ];
        }
      ))
    ])
    [
      "10"
      "11"
    ]
)
