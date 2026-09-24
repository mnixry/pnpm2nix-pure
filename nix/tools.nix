{
  lib,
  stdenv,
  mkPnpmPackage,
  mkPnpmNodeModules,
  nodejs_24,
  makeWrapper,
  autoPatchelfHook,
}:
mkPnpmPackage {
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../package.json
      ../pnpm-lock.yaml
      ../pnpm-workspace.yaml
      ../patches
      ../tsconfig.json
      ../tests/generate.ts
    ];
  };
  packageJSON = ../package.json;
  pnpmLockYaml = ../pnpm-lock.yaml;
  nodejs = nodejs_24;
  nodeModules = mkPnpmNodeModules {
    src = ../.;
    nodejs = nodejs_24;
    extraNodeModuleSources = [
      {
        name = "pnpm-workspace.yaml";
        value = ../pnpm-workspace.yaml;
      }
      {
        name = "patches";
        value = ../patches;
      }
    ];
    extraBuildInputs = lib.optional stdenv.hostPlatform.isLinux autoPatchelfHook;
    buildInputs = lib.optional stdenv.hostPlatform.isLinux stdenv.cc.cc.lib;
    preInstall = "rm -rf node_modules/.pnpm-store";
  };
  script = "typecheck";
  extraBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/tests" "$out/bin"
    cp package.json "$out/lib/"
    cp tests/generate.ts "$out/lib/tests/"
    cp -P node_modules "$out/lib/"
    for tool in oxlint oxfmt; do
      makeWrapper ${lib.getExe nodejs_24} "$out/bin/$tool" \
        --add-flags "$out/lib/node_modules/$tool/bin/$tool"
    done
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/tsc" \
      --add-flags "$out/lib/node_modules/typescript/bin/tsc"
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/yaml" \
      --add-flags "$out/lib/node_modules/yaml/bin.mjs"
    runHook postInstall
  '';
  meta.mainProgram = "oxfmt";
}
