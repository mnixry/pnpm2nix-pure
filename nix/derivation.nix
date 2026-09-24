{
  lib,
  stdenv,
  nodejs,
  pnpm,
  pkg-config,
  callPackage,
  ...
}:

let
  nodePkg = nodejs;
  pnpmPkg = pnpm;
  pkgConfigPkg = pkg-config;
  mkPnpmNodeModules = callPackage ./node-modules.nix { };
  sourcePatchAttrs = lib.genAttrs [
    "patches"
    "patchFlags"
    "patchPhase"
    "prePatch"
    "postPatch"
    "dontPatch"
  ] (_: null);
in
{
  inherit mkPnpmNodeModules;

  mkPnpmPackage = lib.makeOverridable (
    {
      src,
      packageJSON ? src + "/package.json",
      pnpmLockYaml ? src + "/pnpm-lock.yaml",
      pname ? (builtins.fromJSON (builtins.readFile packageJSON)).name,
      version ? (builtins.fromJSON (builtins.readFile packageJSON)).version or null,
      name ? if version != null then "${pname}-${version}" else pname,
      registry ? "https://registry.npmjs.org",
      lockfileResolver ? "regex",
      script ? "build",
      distDir ? "dist",
      installInPlace ? false,
      installEnv ? { },
      noDevDependencies ? false,
      extraNodeModuleSources ? [ ],
      copyNodeModules ? false,
      extraBuildInputs ? [ ],
      nodejs ? nodePkg,
      pnpm ? pnpmPkg,
      pkg-config ? pkgConfigPkg,
      nodeModules ? mkPnpmNodeModules (
        {
          inherit
            src
            packageJSON
            pnpmLockYaml
            registry
            lockfileResolver
            installInPlace
            installEnv
            noDevDependencies
            extraNodeModuleSources
            extraBuildInputs
            nodejs
            pnpm
            pkg-config
            ;
          name = "${name}-node-modules";
        }
        // lib.optionalAttrs installInPlace (builtins.intersectAttrs sourcePatchAttrs attrs)
      ),
      ...
    }@attrs:
    stdenv.mkDerivation (
      finalAttrs:
      {
        inherit
          name
          nodejs
          pnpm
          pkg-config
          nodeModules
          ;
        src = if installInPlace then finalAttrs.nodeModules else src;
        nativeBuildInputs = [
          finalAttrs.nodejs
          finalAttrs.pnpm
          finalAttrs.pkg-config
        ]
        ++ extraBuildInputs;
        configurePhase = ''
          export HOME="$NIX_BUILD_TOP"
          export npm_config_nodedir=${finalAttrs.nodejs}
          export pnpm_config_store_dir="$PWD/node_modules/.pnpm-store"
          export pnpm_config_offline=true
          export pnpm_config_pm_on_fail=ignore
          export pnpm_config_verify_deps_before_run=false
          runHook preConfigure
          ${lib.optionalString (!installInPlace) (
            if copyNodeModules then
              ''
                find ${finalAttrs.nodeModules} -name node_modules -prune -print0 | while IFS= read -r -d "" modules; do
                  target="''${modules#${finalAttrs.nodeModules}/}"
                  mkdir -p "$(dirname "$target")"
                  cp -R "$modules" "$target"
                  chmod -R u+w "$target"
                done
              ''
            else
              ''
                ln -s ${finalAttrs.nodeModules}/node_modules node_modules
              ''
          )}
          runHook postConfigure
        '';
        buildPhase = ''
          runHook preBuild
          pnpm run ${lib.escapeShellArg script}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          ${if distDir == "." then "cp -R" else "mv"} ${lib.escapeShellArg distDir} "$out"
          runHook postInstall
        '';
      }
      // (removeAttrs attrs (
        [
          "src"
          "extraNodeModuleSources"
          "installEnv"
        ]
        ++ lib.optionals installInPlace (builtins.attrNames sourcePatchAttrs)
      ))
      // {
        passthru = {
          inherit attrs;
          inherit (finalAttrs.nodeModules) patchedLockfileYaml;
        }
        // attrs.passthru or { };
      }
    )
  );
}
