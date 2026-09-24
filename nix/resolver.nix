{ lib }:
let
  yaml = import ./yaml.nix { inherit lib; };

  selectDocument =
    environment: noDevDependencies: document:
    let
      packages = document.packages or { };
      snapshots = document.snapshots or { };
      importers = document.importers or { };
      packageKey =
        snapshot:
        if builtins.hasAttr snapshot packages then
          snapshot
        else
          let
            parts = lib.splitString "(" snapshot;
            found =
              builtins.foldl'
                (
                  state: part:
                  let
                    prefix = state.prefix + "(" + part;
                  in
                  {
                    inherit prefix;
                    key = if builtins.hasAttr prefix packages then prefix else state.key;
                  }
                )
                {
                  prefix = builtins.head parts;
                  key = if builtins.hasAttr (builtins.head parts) packages then builtins.head parts else null;
                }
                (builtins.tail parts);
          in
          found.key;
      reference =
        alias: version:
        if lib.hasPrefix "link:" version then
          [ ]
        else
          [ { key = if builtins.hasAttr version snapshots then version else "${alias}@${version}"; } ];
      edges = dependencies: lib.concatLists (lib.mapAttrsToList reference dependencies);
      roots = lib.concatLists (
        lib.mapAttrsToList (
          _: importer:
          lib.concatMap
            (group: edges (lib.mapAttrs (_: dependency: dependency.version) (importer.${group} or { })))
            (
              if environment then
                [ "configDependencies" ]
              else
                [
                  "dependencies"
                  "optionalDependencies"
                  "configDependencies"
                ]
            )
        ) importers
      );
      closure = builtins.genericClosure {
        startSet = roots;
        operator =
          item:
          edges (snapshots.${item.key}.dependencies or { })
          ++ edges (snapshots.${item.key}.optionalDependencies or { });
      };
    in
    if !environment && !noDevDependencies then
      { inherit packages snapshots; }
    else
      {
        packages = lib.getAttrs (map (item: packageKey item.key) closure) packages;
        snapshots = lib.getAttrs (map (item: item.key) closure) snapshots;
      };
in
{
  inherit (yaml) splitDocuments;
  parseLockfile = yaml.parseDocuments;
  selectDependencies =
    {
      documents,
      noDevDependencies ? false,
    }:
    lib.imap0 (
      index: selectDocument (builtins.length documents == 2 && index == 0) noDevDependencies
    ) documents;
}
