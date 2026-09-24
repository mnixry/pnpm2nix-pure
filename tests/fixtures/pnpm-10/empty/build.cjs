const fs = require("node:fs");
const result = { empty: true };
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
