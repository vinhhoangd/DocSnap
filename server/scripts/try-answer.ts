// Local end-to-end check: sends a page image to Claude with the same code the server runs.
// Usage (from server/):  npm run try -- /path/to/page.jpg [model]
// Reads ANTHROPIC_API_KEY from ../.env via `node --env-file`.
import Anthropic from "@anthropic-ai/sdk";
import { readFileSync } from "node:fs";
import { streamAnswer, DEFAULT_MODEL } from "../api/answer.ts";

const [imagePath, model = DEFAULT_MODEL] = process.argv.slice(2);
if (!imagePath) {
  console.error("Usage: npm run try -- /path/to/page.jpg [model]");
  process.exit(2);
}
if (!process.env.ANTHROPIC_API_KEY) {
  console.error("ANTHROPIC_API_KEY is empty in ../.env");
  process.exit(2);
}
const image = readFileSync(imagePath).toString("base64");
const client = new Anthropic();
const started = Date.now();
let firstTokenMs: number | undefined;
for await (const event of streamAnswer(client, { image, model })) {
  if (event.type === "text") {
    firstTokenMs ??= Date.now() - started;
    process.stdout.write(event.text);
  } else {
    console.error(`\n[${JSON.stringify(event)}]`);
  }
}
console.error(`[first text after ${firstTokenMs ?? "-"} ms, total ${Date.now() - started} ms]`);
