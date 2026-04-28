#!/usr/bin/env node
// Embeds docs/INTEGRATION.md into the Worker bundle so /integration.md and the
// landing page can serve it without a runtime fetch. Re-run via `npm run
// sync-docs`; npm `pretest` and `predeploy` invoke it automatically.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const sourceMd = resolve(here, "../../docs/INTEGRATION.md");
const outFile = resolve(here, "../src/generated/integrationDoc.ts");

const md = readFileSync(sourceMd, "utf8");

const banner = `// AUTO-GENERATED — do not edit by hand.
// Source: docs/INTEGRATION.md
// Regenerate with: npm run sync-docs
`;

const body = `${banner}
export const integrationMarkdown = ${JSON.stringify(md)};
`;

mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, body);
console.log(`wrote ${outFile} (${md.length} bytes)`);
