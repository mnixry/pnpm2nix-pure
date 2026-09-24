const fs = require("node:fs");
const result = {
  value: require("fixture-value"),
  development: process.env.FIXTURE_PRODUCTION === "1" ? null : require("fixture-dev"),
};
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
