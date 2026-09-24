{
  pkgs,
  lockfileResolver ? "regex",
}:
let
  inherit (pkgs) lib;
  resolver = import ../nix/resolver.nix { inherit lib; };
  lockfiles = pkgs.callPackage ../nix/lockfile.nix { };
  yaml = import ../nix/yaml.nix { inherit lib; };
  tools = pkgs.callPackage ../nix/tools.nix { };
  files = [
    ../pnpm-lock.yaml
  ]
  ++ builtins.filter (path: baseNameOf path == "pnpm-lock.yaml") (
    lib.filesystem.listFilesRecursive ./fixtures ++ lib.filesystem.listFilesRecursive ./integration
  );
  fixtureName =
    path: lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "${toString ../.}/" (toString path));
  parse = lockfile: lockfiles.parseLockfile { inherit lockfile lockfileResolver; };
  load = name: parse (./integration + "/${name}/pnpm-lock.yaml");
  select =
    documents:
    resolver.selectDependencies {
      inherit documents;
      noDevDependencies = true;
    };
  names = documents: map (document: builtins.attrNames (document.packages or { })) documents;
  test = expr: expected: { inherit expr expected; };
  basic = builtins.head (load "basic");
  basicText = builtins.readFile ./integration/basic/pnpm-lock.yaml;
  basicHash = basic.packages."fixture-value@1.0.0".resolution.integrity;
  source =
    key: resolution:
    lockfiles.resolveSource "https://registry.example.test/" key { inherit resolution; };
  sourceTests = {
    test-local-source-context = test (
      let
        archive = builtins.toFile "fixture-archive.tgz" "fixture archive";
        lockfile = builtins.toFile "context-lock.yaml" (
          builtins.replaceStrings [ "resolution: {" ] [ "resolution: {tarball: 'file:${archive}', " ]
            basicText
        );
      in
      builtins.hasContext
        (builtins.head (parse lockfile)).packages."fixture-value@1.0.0".resolution.tarball
    ) true;
    test-registry = test (source "fixture-value@1.0.0" { integrity = basicHash; }) {
      type = "url";
      url = "https://registry.example.test/fixture-value/-/fixture-value-1.0.0.tgz";
      hash = basicHash;
    };
    test-scoped-registry = test (source "@scope/name@2.0.0-beta.1" { integrity = basicHash; }) {
      type = "url";
      url = "https://registry.example.test/@scope/name/-/name-2.0.0-beta.1.tgz";
      hash = basicHash;
    };
    test-explicit-tarball =
      test
        (source "fixture-value@1.0.0" {
          integrity = basicHash;
          tarball = "https://mirror.test/value.tgz";
        })
        {
          type = "url";
          url = "https://mirror.test/value.tgz";
          hash = basicHash;
        };
    test-reject-subdirectory =
      test
        (builtins.tryEval (
          source "value" {
            integrity = basicHash;
            tarball = "https://example.test/value.tgz";
            path = "packages/value";
          }
        )).success
        false;
    test-reject-git-subdirectory =
      test
        (builtins.tryEval (
          source "value@1.0.0" {
            type = "git";
            repo = "https://example.test/repo.git";
            commit = "0123456789abcdef0123456789abcdef01234567";
            directory = "packages/value";
          }
        )).success
        false;
    test-hosted-git-preparation =
      test
        (source "value@1.0.0" {
          integrity = basicHash;
          tarball = "https://example.test/value.tgz";
          gitHosted = true;
        })
        {
          type = "url";
          url = "https://example.test/value.tgz";
          hash = basicHash;
          gitHosted = true;
        };
  };
  graphTests = {
    test-all-dependencies = test (names (resolver.selectDependencies { documents = [ basic ]; })) [
      [
        "fixture-dev@1.0.0"
        "fixture-value@1.0.0"
      ]
    ];
    test-production = test (names (select [ basic ])) [ [ "fixture-value@1.0.0" ] ];
    test-workspace = test (names (select (load "workspace"))) [ [ "fixture-value@1.0.0" ] ];
    test-config-dependency = test (names (select (load "config-plugin"))) [
      [ "pnpm-plugin-fixture@1.0.0" ]
      [ "fixture-value@1.0.0" ]
    ];
    test-production-peer-context = test (names (select (load "production-peers"))) [
      [
        "fixture-peer@1.0.0"
        "fixture-value@1.0.0"
      ]
    ];
  };
  generatedGraphTests = lib.mergeAttrsList (
    map
      (
        major:
        let
          directory = ./fixtures + "/pnpm-${major}";
          documents = name: parse (directory + "/${name}/pnpm-lock.yaml");
          selected = name: select (documents name);
          longNames =
            builtins.attrNames
              (builtins.fromJSON (builtins.readFile (directory + "/long-peer-key/package.json"))).dependencies;
          longSnapshot =
            "fixture-long-peer@1.0.0"
            + lib.concatMapStrings (name: "(${name}@1.0.0)") (
              builtins.filter (name: name != "fixture-long-peer") longNames
            );
          patchHash = builtins.hashFile "sha256" (directory + "/patched/patches/fixture-value.patch");
        in
        {
          "test-pnpm${major}-cycles-aliases-optional-peer" = test (names (selected "dependency-graph")) [
            [
              "@fixture/scoped@1.0.0-rc.1"
              "fixture-cycle-a@1.0.0"
              "fixture-cycle-b@1.0.0"
              "fixture-dev@1.0.0"
              "fixture-parent@1.0.0"
              "fixture-peer@1.0.0"
              "fixture-platform@1.0.0"
              "fixture-value@1.0.0"
              "fixture-value@2.0.0"
            ]
          ];
          "test-pnpm${major}-large-workspace" = test (names (selected "large-workspace")) [
            [
              "fixture-value@1.0.0"
              "fixture-value@2.0.0"
            ]
          ];
          "test-pnpm${major}-workspace-links" = test (names (selected "workspace-links")) [ [ ] ];
          "test-pnpm${major}-long-peer-identity" =
            test
              {
                packages = names (selected "long-peer-key");
                peer = builtins.filter (key: builtins.stringLength key > 1024) (
                  builtins.attrNames (builtins.head (selected "long-peer-key")).snapshots
                );
              }
              {
                packages = [ (map (name: "${name}@1.0.0") longNames) ];
                peer = [ longSnapshot ];
              };
          "test-pnpm${major}-patch-identity" = test (builtins.attrNames (builtins.head (selected "patched"))
            .snapshots) [ "fixture-value@1.0.0(patch_hash=${patchHash})" ];
        }
      )
      [
        "10"
        "11"
        "12"
      ]
  );
  parserTests = {
    test-crlf = test (resolver.parseLockfile (builtins.replaceStrings [ "\n" ] [ "\r\n" ] basicText)) (
      resolver.parseLockfile basicText
    );
    test-bom = test (resolver.parseLockfile ("﻿" + basicText)) (resolver.parseLockfile basicText);
    test-no-final-newline = test (resolver.parseLockfile (lib.removeSuffix "\n" basicText)) (
      resolver.parseLockfile basicText
    );
    test-comment = test (resolver.parseLockfile ("# generated fixture with a comment\n" + basicText)) (
      resolver.parseLockfile basicText
    );
    test-quoted-null-key =
      test (builtins.head (yaml.parseDocuments (basicText + "\n? 'null'\n: value\n"))).null
        "value";
    test-blank-literal-clip =
      test (builtins.head (yaml.parseDocuments (basicText + "\nprobe: |\n  \n"))).probe
        "";
    test-blank-literal-keep =
      test (builtins.head (yaml.parseDocuments (basicText + "\nprobe: |+\n  \n"))).probe
        "\n";
    test-blank-literal-explicit-indent =
      test (builtins.head (yaml.parseDocuments (basicText + "\nprobe: |2\n   \n"))).probe
        " \n";
  }
  // lib.optionalAttrs (lockfileResolver == "yaml2json") {
    test-ifd-anchor = test (parse (
      builtins.toFile "anchor-lock.yaml" (
        builtins.replaceStrings [ "lockfileVersion:" ] [ "lockfileVersion: &version" ] basicText
      )
    )) (load "basic");
    test-ifd-directive = test (parse (
      builtins.toFile "directive-lock.yaml" ("%YAML 1.2\n---\n" + basicText)
    )) (load "basic");
  };
  evalCheck =
    name: tests:
    builtins.deepSeq (lib.debug.throwTestFailures {
      failures = lib.runTests tests;
      description = "pnpm2nix ${name}";
    }) (pkgs.runCommand "pnpm2nix-${name}" { } ''touch "$out"'');
  pureDocuments = pkgs.runCommand "pnpm-parsed-documents" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir "$out"
    ${lib.concatMapStringsSep "\n" (path: ''
      jq -S . ${pkgs.writeText "parsed.json" (builtins.toJSON (parse path))} > "$out/${fixtureName path}.json"
    '') files}
  '';
  referenceDocuments =
    pkgs.runCommand "pnpm-reference-documents"
      {
        nativeBuildInputs = [
          tools
          pkgs.jq
        ];
      }
      ''
        mkdir "$out"
        ${lib.concatMapStringsSep "\n" (path: ''
          yaml --json --strict < ${path} > document.json
          jq -S . document.json > "$out/${fixtureName path}.json"
        '') files}
      '';
  fakeFetch = args: pkgs.writeText "fixture-archive.tgz" args.url;
  rewrite = pkgs.callPackage ../nix/lockfile.nix { fetchurl = fakeFetch; };
  rewritten = rewrite.processLockfile {
    registry = "https://registry.example.test";
    lockfile = ./integration/basic/pnpm-lock.yaml;
    noDevDependencies = true;
    inherit lockfileResolver;
  };
  expectedRewrite = [
    (
      basic
      // {
        lockfileVersion = "9.0";
        snapshots = removeAttrs basic.snapshots [ "fixture-dev@1.0.0" ];
        packages = basic.packages // {
          "fixture-value@1.0.0" = basic.packages."fixture-value@1.0.0" // {
            resolution = {
              integrity = basicHash;
              tarball = "file:${
                fakeFetch { url = "https://registry.example.test/fixture-value/-/fixture-value-1.0.0.tgz"; }
              }";
            };
          };
        };
      }
    )
  ];
  rewriteActual =
    pkgs.runCommand "rewritten-document.json"
      {
        nativeBuildInputs = [
          tools
          pkgs.jq
        ];
      }
      ''
        yaml --json --strict < ${rewritten.patchedLockfileYaml} > document.json
        jq -S . document.json > "$out"
      '';
  rewriteExpected = pkgs.runCommand "expected-rewrite.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq -S . ${pkgs.writeText "expected.json" (builtins.toJSON expectedRewrite)} > "$out"
  '';
  provenance = builtins.fromJSON (builtins.readFile ./fixtures/provenance.json);
  hashes = paths: lib.mapAttrs (path: _: builtins.hashFile "sha256" (../. + "/${path}")) paths;
  provenanceTests = {
    test-lockfile-provenance = test (lib.mapAttrs (
      directory: _: builtins.hashFile "sha256" (../. + "/${directory}/pnpm-lock.yaml")
    ) provenance.fixtures) (lib.mapAttrs (_: record: record.lockfileSha256) provenance.fixtures);
    test-input-provenance = test (lib.mapAttrs (
      directory: record:
      lib.mapAttrs (path: _: builtins.hashFile "sha256" (../. + "/${directory}/${path}")) record.inputs
    ) provenance.fixtures) (lib.mapAttrs (_: record: record.inputs) provenance.fixtures);
    test-source-provenance = test (hashes provenance.sources) provenance.sources;
    test-archive-provenance = test (hashes provenance.archives) provenance.archives;
    test-recorded-corpus =
      test
        (builtins.sort builtins.lessThan (
          map (path: lib.removePrefix "${toString ../.}/" (toString path)) (
            builtins.filter (path: lib.hasPrefix (toString ./fixtures) (toString path)) files
          )
        ))
        (
          builtins.sort builtins.lessThan (
            map (directory: "${directory}/pnpm-lock.yaml") (builtins.attrNames provenance.fixtures)
          )
        );
    test-integration-locks =
      test
        (map (path: builtins.hashFile "sha256" path) (
          builtins.filter (path: lib.hasPrefix (toString ./integration) (toString path)) files
        ))
        (
          map (
            path: builtins.hashFile "sha256" (./fixtures/pnpm-12 + "/${baseNameOf (dirOf path)}/pnpm-lock.yaml")
          ) (builtins.filter (path: lib.hasPrefix (toString ./integration) (toString path)) files)
        );
  };
in
{
  fixture-provenance = evalCheck "fixture-provenance" provenanceTests;
  sources = evalCheck "sources" sourceTests;
  dependency-graphs = evalCheck "dependency-graphs" (graphTests // generatedGraphTests);
  parser-boundaries = evalCheck "parser-boundaries" parserTests;
  yaml-reference = pkgs.testers.testEqualContents {
    assertion = "pnpm-yaml-documents";
    actual = pureDocuments;
    expected = referenceDocuments;
    checkMetadata = false;
  };
  lockfile-rewrite = pkgs.testers.testEqualContents {
    assertion = "pnpm-lockfile-rewrite";
    actual = rewriteActual;
    expected = rewriteExpected;
    checkMetadata = false;
  };
}
