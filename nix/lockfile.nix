{
  lib,
  runCommand,
  remarshal,
  writeText,
  fetchurl,
  ...
}:

let
  resolver = import ./resolver.nix { inherit lib; };
  resolveSource =
    registry: key: package:
    let
      resolution = package.resolution;
      github = builtins.match "https://codeload.github.com/([^/]+)/([^/]+)/tar\\.gz/([^/]+)" (
        resolution.tarball or ""
      );
      registryKey = builtins.match "(@[^/]+/[^@/]+|[^@/]+)@([^()/@:]+)" key;
      git = url: rev: {
        type = "git";
        inherit url rev;
      };
    in
    # Fetching the whole source would build a different package.
    if resolution ? path || resolution ? directory then
      throw "pnpm2nix: source subdirectories are unsupported: ${key}"
    else if (resolution.type or "") == "git" then
      git resolution.repo resolution.commit
    else if github != null && !(resolution ? integrity) then
      git "https://github.com/${builtins.elemAt github 0}/${builtins.elemAt github 1}" (
        builtins.elemAt github 2
      )
    else
      let
        name = builtins.elemAt registryKey 0;
        version = builtins.elemAt registryKey 1;
      in
      {
        type = "url";
        url =
          resolution.tarball
            or "${lib.removeSuffix "/" registry}/${name}/-/${baseNameOf name}-${version}.tgz";
        hash = resolution.integrity;
      }
      // lib.optionalAttrs ((resolution.gitHosted or false) || github != null) { gitHosted = true; };

  parseLockfile =
    {
      lockfile,
      lockfileResolver ? "regex",
    }:
    let
      text = builtins.readFile lockfile;
      documents =
        {
          regex = resolver.parseLockfile text;
          yaml2json = map (
            document:
            let
              json = builtins.readFile (
                runCommand "pnpm-lock-document.json" { nativeBuildInputs = [ remarshal ]; } ''
                  yaml2json ${writeText "pnpm-lock-document.yaml" document} "$out"
                ''
              );
            in
            builtins.fromJSON (builtins.unsafeDiscardStringContext json)
          ) (resolver.splitDocuments text);
        }
        .${lockfileResolver};
    in
    map (lib.mapAttrsRecursive (
      path: value:
      # Regex captures and JSON decoding lose dependencies of local source URLs.
      if
        builtins.elem (lib.last path) [
          "tarball"
          "repo"
        ]
        && builtins.isString value
      then
        lib.addContextFrom text value
      else
        value
    )) documents;
in
{
  inherit resolveSource parseLockfile;

  processLockfile =
    {
      registry,
      lockfile,
      noDevDependencies ? false,
      lockfileResolver ? "regex",
    }:
    let
      documents = parseLockfile { inherit lockfile lockfileResolver; };
      selected = resolver.selectDependencies { inherit documents noDevDependencies; };
      resolutions = map (lib.mapAttrs (
        key: package:
        let
          source = resolveSource registry key package;
          tarball =
            if source.type == "url" then
              fetchurl { inherit (source) url hash; }
            else
              let
                contents = fetchGit {
                  inherit (source) url rev;
                  shallow = true;
                };
              in
              runCommand "pnpm-git-source.tgz" { } ''
                tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -czf "$out" -C ${contents} .
              '';
        in
        {
          tarball = "file:${tarball}";
        }
        // lib.optionalAttrs (source.type == "url") { integrity = source.hash; }
        # Replacing the URL removes pnpm's hosted-Git inference. Keep its
        # preparation and packlist behavior for the local archive.
        // lib.optionalAttrs (source.type == "git" || (source.gitHosted or false)) { gitHosted = true; }
      )) (map (document: document.packages) selected);
      patchedDocuments = lib.imap0 (
        index: document:
        let
          replacements = builtins.elemAt resolutions index;
        in
        document
        // {
          lockfileVersion = "9.0";
        }
        // lib.optionalAttrs (document ? packages) {
          packages = lib.mapAttrs (
            key: package:
            package
            // lib.optionalAttrs (replacements ? ${key}) {
              resolution = replacements.${key};
            }
          ) document.packages;
        }
        # pnpm 12 fetches every snapshot even with --prod.
        // lib.optionalAttrs (document ? snapshots) {
          snapshots = (builtins.elemAt selected index).snapshots;
        }
      ) documents;
    in
    {
      patchedLockfileYaml = writeText "pnpm-lock.yaml" (
        lib.concatMapStrings (
          document:
          lib.optionalString (builtins.length patchedDocuments > 1) "---\n" + builtins.toJSON document + "\n"
        ) patchedDocuments
      );
    };
}
