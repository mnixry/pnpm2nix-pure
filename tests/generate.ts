// Regenerate real pnpm locks; run from the repository root via the flake app.

import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { parseArgs, promisify } from "node:util";
import { serve } from "srvx";

interface Manifest {
  name: string;
  version: string;
  optionalDependencies?: Record<string, string>;
  [field: string]: unknown;
}

type Manifests = Record<string, Record<string, Manifest>>;
type Archives = Record<string, Record<string, string>>;

interface Provenance {
  writers: Record<string, string>;
  fixtures: Record<
    string,
    {
      pnpm: string;
      inputs: Record<string, string>;
      lockfileSha256: string;
    }
  >;
  sources?: Record<string, string>;
  archives?: Record<string, string>;
}

const execFileAsync = promisify(execFile);
const versions: Record<string, string> = { 10: "10.34.5", 11: "11.27.0", 12: "12.3.4" };
const integrations = [
  "basic",
  "binary",
  "empty",
  "workspace",
  "native",
  "patched",
  "production-peers",
  "git",
  "tarball",
  "config-plugin",
];

function writeJson(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function digest(path: string) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function files(directory: string): string[] {
  return readdirSync(directory)
    .sort()
    .flatMap((name) => {
      const path = join(directory, name);
      return statSync(path).isDirectory() ? files(path) : [path];
    });
}

async function run(command: string[], env: NodeJS.ProcessEnv) {
  console.log(`+ ${command.join(" ")}`);
  const child = spawn(command[0], command.slice(1), { env, stdio: "inherit" });
  const [code, signal] = await once(child, "close");
  if (code !== 0) {
    throw new Error(`${command[0]} failed (${signal ?? `exit ${code}`})`);
  }
}

async function registryServer(directory: string) {
  const server = serve({
    hostname: "127.0.0.1",
    port: 0,
    silent: true,
    fetch(request) {
      try {
        const pathname = decodeURIComponent(new URL(request.url).pathname);
        let path = resolve(directory, `.${pathname}`);
        if (!path.startsWith(`${directory}${sep}`)) return new Response(null, { status: 404 });
        if (statSync(path).isDirectory()) path = join(path, "index.html");
        const content = readFileSync(path);
        return new Response(request.method === "HEAD" ? null : content, {
          headers: { "Content-Length": String(content.length) },
        });
      } catch (error) {
        const { code } = error as NodeJS.ErrnoException;
        return new Response(null, { status: code === "ENOENT" || code === "ENOTDIR" ? 404 : 500 });
      }
    },
  });
  await server.ready();
  return server;
}

async function packRegistry(root: string, temporary: string, pnpm: string, env: NodeJS.ProcessEnv) {
  const registry = join(temporary, "registry");
  mkdirSync(registry);
  const manifests: Manifests = {};
  const archives: Archives = {};
  const output = join(root, "tests/integration/registry");
  for (const source of readdirSync(join(root, "tests/integration/sources")).sort()) {
    const projectPath = join(temporary, "pack", source);
    cpSync(join(root, "tests/integration/sources", source), projectPath, {
      recursive: true,
      dereference: true,
    });
    const destination = join(temporary, "archives", source);
    mkdirSync(destination, { recursive: true });
    await run([pnpm, "--dir", projectPath, "pack", "--pack-destination", destination], env);
    const packed = readdirSync(destination).filter((name) => name.endsWith(".tgz"));
    if (packed.length !== 1) throw new Error(`Expected one packed archive in ${destination}`);
    const archive = join(destination, packed[0]);
    const { stdout } = await execFileAsync("tar", ["-xOf", archive, "package/package.json"]);
    const manifest: Manifest = JSON.parse(stdout);
    const { name, version } = manifest;
    const archivePath = join(name, "-", `${name.split("/").at(-1)}-${version}.tgz`);
    for (const directory of [registry, output]) {
      const target = join(directory, archivePath);
      mkdirSync(dirname(target), { recursive: true });
      copyFileSync(archive, target);
    }
    (manifests[name] ??= {})[version] = manifest;
    (archives[name] ??= {})[version] = archivePath;
  }
  return { registry, manifests, archives };
}

function registryMetadata(
  directory: string,
  url: string,
  manifests: Manifests,
  archives: Archives,
) {
  for (const [name, releases] of Object.entries(manifests)) {
    const entries: Record<string, Manifest> = {};
    for (const [version, manifest] of Object.entries(releases)) {
      const archivePath = archives[name][version];
      const integrity = createHash("sha512")
        .update(readFileSync(join(directory, archivePath)))
        .digest("base64");
      entries[version] = {
        ...manifest,
        dist: { tarball: `${url}/${archivePath}`, integrity: `sha512-${integrity}` },
      };
    }
    writeJson(join(directory, name, "index.html"), {
      name,
      "dist-tags": { latest: Object.keys(releases).sort().at(-1) },
      versions: entries,
    });
  }
}

async function bootstrapMetadata(directory: string) {
  // The environment resolver needs genuine platform metadata even with pnpm installed.
  const pending: [string, string][] = [["pnpm", versions[12]]];
  const seen = new Set<string>();
  while (pending.length) {
    const [name, version] = pending.pop()!;
    const key = `${name}@${version}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const response = await fetch(`https://registry.npmjs.org/${name}/${version}`);
    if (!response.ok) throw new Error(`${response.url}: HTTP ${response.status}`);
    const manifest: Manifest = await response.json();
    writeJson(join(directory, name, "index.html"), {
      name,
      "dist-tags": { latest: version },
      versions: { [version]: manifest },
    });
    pending.push(...Object.entries(manifest.optionalDependencies ?? {}));
  }
}

function copyProject(source: string, target: string) {
  cpSync(source, target, {
    recursive: true,
    dereference: true,
    filter: (path) => !["pnpm-lock.yaml", "node_modules", "dist"].includes(basename(path)),
  });
}

function project(path: string, name: string, fields: Partial<Manifest> = {}) {
  writeJson(join(path, "package.json"), {
    name: `fixture-${name}`,
    version: "1.0.0",
    private: true,
    ...fields,
  });
}

function extraProjects(directory: string, manifests: Manifests) {
  project(join(directory, "dependency-graph"), "dependency-graph", {
    dependencies: {
      "fixture-value": "2.0.0",
      "fixture-parent": "1.0.0",
      "value-alias": "npm:fixture-value@1.0.0",
      "@fixture/scoped": "1.0.0-rc.1",
      "fixture-cycle-a": "1.0.0",
      "fixture-peer": "1.0.0",
    },
    devDependencies: { "fixture-dev": "1.0.0" },
    optionalDependencies: { "fixture-platform": "1.0.0" },
  });
  project(join(directory, "metadata"), "metadata", {
    dependencies: Object.fromEntries(
      Object.keys(manifests)
        .filter((name) => name.startsWith("fixture-meta-"))
        .map((name) => [name, "1.0.0"]),
    ),
  });
  project(join(directory, "long-peer-key"), "long-peer-key", {
    dependencies: Object.fromEntries(
      Object.keys(manifests)
        .filter((name) => name.startsWith("fixture-long-"))
        .map((name) => [name, "1.0.0"]),
    ),
  });
  writeFileSync(
    join(directory, "long-peer-key/pnpm-workspace.yaml"),
    "peersSuffixMaxLength: 4096\n",
  );
  project(join(directory, "large-workspace"), "large-workspace");
  writeFileSync(
    join(directory, "large-workspace/pnpm-workspace.yaml"),
    "packages:\n  - packages/*\n",
  );
  for (let index = 0; index < 48; index++) {
    const dependencies: Record<string, string> = { "fixture-value": index % 2 ? "1.0.0" : "2.0.0" };
    if (index) dependencies[`fixture-member-${index - 1}`] = "workspace:*";
    project(join(directory, `large-workspace/packages/member-${index}`), `member-${index}`, {
      dependencies,
    });
  }
  project(join(directory, "workspace-links"), "workspace-links", {
    dependencies: { "fixture-local": "workspace:*" },
  });
  writeFileSync(
    join(directory, "workspace-links/pnpm-workspace.yaml"),
    "packages:\n  - packages/*\n",
  );
  project(join(directory, "workspace-links/packages/local"), "local");
}

async function installLock(
  pnpm: string,
  major: number,
  projectPath: string,
  registry: string,
  temporary: string,
  env: NodeJS.ProcessEnv,
) {
  const command = [
    pnpm,
    "--dir",
    projectPath,
    "install",
    "--lockfile-only",
    "--no-frozen-lockfile",
    "--ignore-scripts",
    "--registry",
    registry,
    "--store-dir",
    join(temporary, `store-${major}`),
  ];
  if (major >= 12) {
    command.push(
      "--state-dir",
      join(temporary, "state"),
      "--npmrc-auth-file",
      join(temporary, "empty.npmrc"),
    );
  }
  await run(command, env);
}

function argumentError(message: string): never {
  console.error(`generate.ts: error: ${message}`);
  process.exit(2);
}

async function main() {
  let args;
  try {
    ({ values: args } = parseArgs({
      options: {
        pnpm10: { type: "string" },
        pnpm11: { type: "string" },
        pnpm12: { type: "string" },
        "local-only": { type: "boolean", default: false },
        help: { type: "boolean", short: "h" },
      },
    }));
  } catch (error) {
    argumentError((error as Error).message);
  }
  if (args.help) {
    console.log(`Regenerate real pnpm locks; run from the repository root via the flake app.

Usage: generate.ts --pnpm10 PATH --pnpm11 PATH --pnpm12 PATH [--local-only]

  --local-only  regenerate only controlled local fixtures without upstream access
  -h, --help    show this help message`);
    return;
  }
  const root = process.cwd();
  if (!existsSync(join(root, "tests/integration/sources"))) {
    argumentError("run from the pnpm2nix repository root");
  }
  const binaries = Object.fromEntries(
    Object.entries({ 10: args.pnpm10, 11: args.pnpm11, 12: args.pnpm12 }).map(([major, binary]) => {
      if (!binary) argumentError(`--pnpm${major} is required`);
      return [major, binary] as const;
    }),
  );
  for (const [major, binary] of Object.entries(binaries)) {
    const { stdout } = await execFileAsync(binary, ["--version"]);
    const actual = stdout.trim();
    if (actual !== versions[major]) {
      argumentError(`pnpm ${major}: expected ${versions[major]}, got ${actual}`);
    }
  }
  const provenancePath = join(root, "tests/fixtures/provenance.json");
  const provenance: Provenance = existsSync(provenancePath)
    ? JSON.parse(readFileSync(provenancePath, "utf8"))
    : { writers: versions, fixtures: {} };
  const temporary = mkdtempSync(join(tmpdir(), "pnpm2nix-generate-"));
  try {
    writeFileSync(join(temporary, "empty.npmrc"), "");
    const env = {
      ...process.env,
      CI: "true",
      COREPACK_ENABLE_PROJECT_SPEC: "0",
      npm_config_manage_package_manager_versions: "false",
      npm_config_update_notifier: "false",
      npm_config_userconfig: join(temporary, "empty.npmrc"),
      XDG_CACHE_HOME: join(temporary, "cache"),
      XDG_CONFIG_HOME: join(temporary, "config"),
      XDG_DATA_HOME: join(temporary, "data"),
      PNPM_HOME: join(temporary, "pnpm-home"),
    };
    const { registry, manifests, archives } = await packRegistry(
      root,
      temporary,
      binaries[12],
      env,
    );
    if (!args["local-only"]) await bootstrapMetadata(registry);
    const templates = join(temporary, "templates");
    for (const name of integrations) {
      if (args["local-only"] && ["binary", "git", "tarball", "config-plugin"].includes(name))
        continue;
      copyProject(join(root, "tests/integration", name), join(templates, name));
    }
    extraProjects(templates, manifests);
    const server = await registryServer(registry);
    try {
      const url = server.url!.replace(/\/$/, "");
      registryMetadata(registry, url, manifests, archives);
      for (const [major, pnpm] of Object.entries(binaries)) {
        for (const name of readdirSync(templates).sort()) {
          if (name === "config-plugin" && Number(major) < 12) continue;
          const template = join(templates, name);
          const target = join(temporary, `pnpm-${major}`, name);
          copyProject(template, target);
          await installLock(
            pnpm,
            Number(major),
            target,
            name === "binary" ? "https://registry.npmjs.org" : url,
            temporary,
            env,
          );
          if (
            name === "long-peer-key" &&
            !readFileSync(join(target, "pnpm-lock.yaml"), "utf8").includes("\n  ? ")
          ) {
            throw new Error(`pnpm ${major} did not emit the explicit long-key fixture`);
          }
          const destination = join(root, "tests/fixtures", `pnpm-${major}`, name);
          rmSync(destination, { recursive: true, force: true });
          copyProject(template, destination);
          copyFileSync(join(target, "pnpm-lock.yaml"), join(destination, "pnpm-lock.yaml"));
          if (major === "12" && integrations.includes(name)) {
            copyFileSync(
              join(target, "pnpm-lock.yaml"),
              join(root, "tests/integration", name, "pnpm-lock.yaml"),
            );
          }
          record(provenance, root, destination, versions[major]);
        }
      }
    } finally {
      await server.close(true);
    }
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
  provenance.sources = Object.fromEntries(
    files(join(root, "tests/integration/sources")).map((path) => [
      relative(root, path),
      digest(path),
    ]),
  );
  provenance.archives = Object.fromEntries(
    files(join(root, "tests/integration/registry"))
      .filter((path) => path.endsWith(".tgz"))
      .map((path) => [relative(root, path), digest(path)]),
  );
  writeJson(provenancePath, provenance);
}

function record(provenance: Provenance, root: string, directory: string, version: string) {
  provenance.fixtures[relative(root, directory)] = {
    pnpm: version,
    inputs: Object.fromEntries(
      files(directory)
        .filter((path) => basename(path) !== "pnpm-lock.yaml")
        .map((path) => [relative(directory, path), digest(path)]),
    ),
    lockfileSha256: digest(join(directory, "pnpm-lock.yaml")),
  };
}

await main();
