import { writeFileSync } from "node:fs";

const value: number = 42;
writeFileSync("dist/result.json", JSON.stringify({ value }) + "\n");
