const fs = require("node:fs");
const result = {
  value: require("fixture-value"),
  marker: fs.readFileSync(process.env.PNPM2NIX_PLUGIN_MARKER, "utf8"),
};
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
