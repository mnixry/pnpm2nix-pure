# pnpm2nix

Build pnpm projects with Nix using lockfile version 9. The flake follows
`nixpkgs-unstable`; the current pin provides pnpm 12.3.4 and Node.js 24.20.0.
Flake outputs target aarch64-darwin, aarch64-linux, and x86_64-linux.

Use `pnpm2nix.lib.${system}.mkPnpmPackage`, apply
`pnpm2nix.overlays.default` to access `pkgs.mkPnpmPackage` and
`pkgs.mkPnpmNodeModules`, or import directly:

```nix
let
  inherit (pkgs.callPackage ./nix/derivation.nix { }) mkPnpmPackage;
in mkPnpmPackage {
  src = ./my-project;
}
```

The default `lockfileResolver = "regex"` uses a generic YAML subset parser
written with Nix builtins. It assumes trusted pnpm-generated version 9 locks
and reads complete documents, including block and flow mappings and sequences,
quoted scalars and escapes, literal blocks, and long explicit keys.
The resolver accepts one project document or an
environment document followed by a project document. Nix updates resolutions
and selected snapshots while preserving other metadata, then emits JSON
documents that pnpm reads as YAML. This path evaluates with
`allow-import-from-derivation = false`.

For YAML constructs outside that subset, including anchors and aliases, select
`lockfileResolver = "yaml2json"`. This resolver explicitly uses import from
derivation. Both resolvers share source handling and dependency selection.
Malformed or manually edited locks have no validation guarantees. NUL bytes
cannot be represented by Nix strings.

Registry packages and explicit tarball URLs use the lockfile's integrity hash
with Nix's fetcher. Git resolutions use the recorded commit; GitHub codeload
URLs without integrity are also fetched as Git sources. Git sources are fetched
at evaluation time and repacked during the build. Pure resolution avoids IFD,
but fetching an uncached Git source can still require network access.
Alternate registries use explicit tarball URLs. Hosted Git archives retain
pnpm's preparation and packlist behavior after their URLs are replaced with
local paths. Preparation runs
offline and fails if it needs uncached dependencies. Directory, runtime, and
Git subdirectory resolutions are unsupported.

Dependencies install directly from Nix-provided tarballs with an empty local
store and `pnpm install --frozen-lockfile --offline --trust-lockfile`.
Development dependencies are omitted when `noDevDependencies = true`; the
resolver traverses production and optional dependencies across all workspace
importers and removes unreachable snapshots from the install lockfile.
Configuration dependencies remain available. The installed pnpm
handles package-manager execution; environment bootstrap packages are omitted.

`mkPnpmNodeModules` installs dependencies without running the project's build
script. `mkPnpmPackage` consumes that derivation and runs the selected script.
Dependency scripts follow the project's pnpm `allowBuilds` policy. Supply
`pnpm-workspace.yaml`, workspace packages, patches, and any files needed by
install scripts through `extraNodeModuleSources`, or use `installInPlace = true`.
Isolated installation exports the staged workspace alongside `node_modules`
so workspace links remain valid. With `installInPlace = true`, the dependency
derivation installs into the full source tree; the script derivation unpacks
that result as its writable source, preserving changes made by install scripts.
Source patch hooks run before dependency installation in this mode.

```nix
mkPnpmPackage {
  src = ./my-project;
  extraNodeModuleSources = [
    { name = "pnpm-workspace.yaml"; value = ./my-project/pnpm-workspace.yaml; }
    { name = "packages"; value = ./my-project/packages; }
  ];
}
```

Build or override dependencies independently, then pass them to the script
derivation:

```nix
let
  src = ./my-project;
  nodeModules = (pkgs.mkPnpmNodeModules { inherit src; }).overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.cmake ];
    buildInputs = [ pkgs.openssl ];
  });
in pkgs.mkPnpmPackage {
  inherit src nodeModules;
}
```

Both constructors support `.override`; the dependency and script derivations
also support `.overrideAttrs`. Installation hooks and native library inputs
belong on `nodeModules`. This repository exposes its own dependencies as
`packages.${system}.nodeModules`, buildable with `nix build .#nodeModules`.

The function accepts `stdenv.mkDerivation` attributes, plus:

| Argument | Default | Purpose |
| --- | --- | --- |
| `src` | required | Project source |
| `packageJSON` | `${src}/package.json` | Package manifest |
| `pnpmLockYaml` | `${src}/pnpm-lock.yaml` | Version 9 lockfile |
| `nodeModules` | `mkPnpmNodeModules` with the installation arguments | Dependency derivation consumed by the script build |
| `pname`, `version` | from manifest | Package identity |
| `name` | `${pname}-${version}` | Derivation name; omits version when absent |
| `nodejs`, `pnpm` | `pkgs.nodejs`, `pkgs.pnpm` | Build tools |
| `pkg-config` | `pkgs.pkg-config` | Native dependency configuration |
| `registry` | `https://registry.npmjs.org` | Default registry |
| `lockfileResolver` | `"regex"` | `"regex"` or `"yaml2json"` |
| `script` | `"build"` | Script run after installation |
| `distDir` | `"dist"` | Output directory; `"."` copies the project |
| `installInPlace` | `false` | Install into the full source tree, then build from that result |
| `installEnv` | `{}` | Variables exported during dependency installation |
| `noDevDependencies` | `false` | Fetch and install production dependencies only |
| `extraNodeModuleSources` | `[]` | Files staged for isolated installation; paths or `{ name; value; }` entries |
| `copyNodeModules` | `false` | Copy installed modules instead of linking them |
| `extraBuildInputs` | `[]` | Additional native build inputs |

The result exposes `nodeModules`, `patchedLockfileYaml`, and `attrs` as passthru
attributes.

The flake-parts configuration provides native Nix tests, treefmt checks,
the formatter, and a development shell. Run the checks and offline integration
builds with:

```sh
nix flake check --option allow-import-from-derivation false
```

When testing an unstaged checkout, use `nix flake check path:.` so Nix includes
new fixture files. The same suites can also exercise the IFD resolver:

```sh
nix build --impure --option allow-import-from-derivation true --expr '
  let
    flake = builtins.getFlake ("path:" + toString ./.);
    pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.extend flake.overlays.default;
    args = { inherit pkgs; lockfileResolver = "yaml2json"; };
  in builtins.attrValues ((import ./tests args) // (import ./tests/integration.nix args))'
```

Regenerate the fixture corpus with the pinned pnpm 10, 11, and 12 writers:

```sh
nix run .#regenerate-fixtures
```

Generation may fetch pinned upstream Git, tarball, package-manager, and esbuild sources.
Ordinary checks use the committed corpus. See [tests/README.md](tests/README.md)
for generation provenance and coverage. Use `nix fmt` to format maintained
source files; generated fixture artifacts are excluded.

The TypeScript generator runs directly on Node.js 24 and uses srvx for its
temporary registry. Building `packages.${system}.tools` runs `tsc --noEmit`;
`nix fmt` checks the source with oxlint and formats it with oxfmt. These npm
tools and the YAML reference CLI are built through this repository's
`mkPnpmNodeModules` and `mkPnpmPackage` from the root lockfile, and are available
in the development shell. The reference check uses the YAML CLI's complete
stream parser; no custom conversion script is needed.
