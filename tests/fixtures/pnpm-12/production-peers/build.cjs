const fs = require("node:fs");
const result = { value: require("fixture-peer") };
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
