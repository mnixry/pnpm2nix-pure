{
  lib,
  stdenv,
  nodejs,
  pnpm,
  pkg-config,
  callPackage,
}:
let
  nodePkg = nodejs;
  pnpmPkg = pnpm;
  pkgConfigPkg = pkg-config;
  lockfiles = callPackage ./lockfile.nix { };
in
lib.makeOverridable (
  {
    src,
    packageJSON ? src + "/package.json",
    pnpmLockYaml ? src + "/pnpm-lock.yaml",
    pname ? (builtins.fromJSON (builtins.readFile packageJSON)).name,
    version ? (builtins.fromJSON (builtins.readFile packageJSON)).version or null,
    name ? "${if version != null then "${pname}-${version}" else pname}-node-modules",
    registry ? "https://registry.npmjs.org",
    lockfileResolver ? "regex",
    installInPlace ? false,
    installEnv ? { },
    noDevDependencies ? false,
    extraNodeModuleSources ? [ ],
    extraBuildInputs ? [ ],
    nodejs ? nodePkg,
    pnpm ? pnpmPkg,
    pkg-config ? pkgConfigPkg,
    ...
  }@attrs:
  let
    processResult = lockfiles.processLockfile {
      inherit registry noDevDependencies lockfileResolver;
      lockfile = pnpmLockYaml;
    };
  in
  stdenv.mkDerivation (
    finalAttrs:
    (
      {
        inherit
          name
          nodejs
          pnpm
          pkg-config
          ;
        nativeBuildInputs = [
          finalAttrs.nodejs
          finalAttrs.pnpm
          finalAttrs.pkg-config
        ]
        ++ extraBuildInputs;
        dontConfigure = true;
        buildPhase = ''
          export HOME="$NIX_BUILD_TOP"
          export npm_config_nodedir=${finalAttrs.nodejs}
          export pnpm_config_store_dir="$PWD/node_modules/.pnpm-store"
          export pnpm_config_offline=true
          export pnpm_config_pm_on_fail=ignore
          export pnpm_config_verify_deps_before_run=false
          ${lib.toShellVars installEnv}
          ${lib.concatMapStringsSep "\n" (name: "export ${name}") (builtins.attrNames installEnv)}
          runHook preBuild
          cp -f ${processResult.patchedLockfileYaml} pnpm-lock.yaml
          pnpm install ${lib.optionalString noDevDependencies "--prod "}--frozen-lockfile --offline --trust-lockfile
          runHook postBuild
        '';
        # Workspace links and install-script output must travel with node_modules.
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp -R . "$out"
          runHook postInstall
        '';
      }
      // (
        if installInPlace then
          { inherit src; }
        else
          {
            sourceRoot = "source";
            unpackPhase = ''
              runHook preUnpack
              mkdir source
              ${lib.concatMapStringsSep "\n" (
                source:
                let
                  item = if builtins.isAttrs source then source else lib.nameValuePair "." source;
                in
                ''
                  mkdir -p ${lib.escapeShellArg ("source/" + dirOf item.name)}
                  cp -R ${lib.escapeShellArg "${item.value}"} ${lib.escapeShellArg ("source/" + item.name)}
                ''
              ) ((lib.singleton (lib.nameValuePair "package.json" packageJSON)) ++ extraNodeModuleSources)}
              chmod -R u+w source
              runHook postUnpack
            '';
          }
      )
    )
    // (removeAttrs attrs [
      "src"
      "extraNodeModuleSources"
      "installEnv"
    ])
    // {
      passthru = {
        inherit (processResult) patchedLockfileYaml;
      }
      // attrs.passthru or { };
    }
  )
)
