const { spawnSync } = require("node:child_process");

const result = spawnSync(process.env.CC || "cc", [
  "-shared", "-fPIC",
  ...(process.platform === "darwin" ? ["-undefined", "dynamic_lookup"] : []),
  `-I${process.env.npm_config_nodedir}/include/node`,
  "addon.c", "-o", "addon.node",
], { stdio: "inherit" });
if (result.error) throw result.error;
process.exit(result.status);
