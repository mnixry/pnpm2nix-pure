const fs = require("node:fs");
const result = { value: require("fixture-library") };
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
