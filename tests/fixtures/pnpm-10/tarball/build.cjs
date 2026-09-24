const fs = require("node:fs");
const result = { number: require("is-number")(42), nonNumber: require("is-number")("not a number") };
fs.mkdirSync("dist");
fs.writeFileSync("dist/result.json", JSON.stringify(result) + "\n");
