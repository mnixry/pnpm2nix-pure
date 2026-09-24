const fs = require("node:fs");
const result = { value: require("fixture-value") };
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
