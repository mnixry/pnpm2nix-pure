const fs = require("node:fs");
const result = {
  value: process.env.FIXTURE_BUILD_ALLOWED === "1" ? require("fixture-native") : null,
  source: fs.existsSync("node_modules/fixture-native/addon.c"),
  headers: fs.existsSync(`${process.env.npm_config_nodedir}/include/node/node_api.h`),
};
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
