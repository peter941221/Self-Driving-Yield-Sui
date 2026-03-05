import fs from "node:fs";
import path from "node:path";

// Aftermath SDK (as of v2.0.0) imports `dayjs/plugin/duration` without an
// extension, which breaks under Node ESM resolution on newer Node versions.
// This tiny patch keeps the PoC runnable without pinning Node or forking deps.
const target = path.join(
  process.cwd(),
  "node_modules",
  "aftermath-ts-sdk",
  "dist",
  "index.js"
);

if (!fs.existsSync(target)) {
  console.log("[patch] skip (not installed):", target);
  process.exit(0);
}

const src = fs.readFileSync(target, "utf8");
const next = src.replace(
  'import duration from "dayjs/plugin/duration";',
  'import duration from "dayjs/plugin/duration.js";'
);

if (src === next) {
  console.log("[patch] already applied:", target);
  process.exit(0);
}

fs.writeFileSync(target, next);
console.log("[patch] applied:", target);

