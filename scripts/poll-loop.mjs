// Continuous polling loop — runs poll.mjs logic every 2 minutes
// Usage: node scripts/poll-loop.mjs
// Stop with Ctrl+C

import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const POLL_SCRIPT = path.join(__dirname, "poll.mjs");
const INTERVAL_MS = 2 * 60 * 1000; // 2 minutes

let running = false;

async function runOnce() {
  if (running) return;
  running = true;
  const start = Date.now();

  return new Promise((resolve) => {
    const child = execFile("node", [POLL_SCRIPT], {
      cwd: path.join(__dirname, ".."),
      timeout: 60000,
    }, (err, stdout, stderr) => {
      const elapsed = ((Date.now() - start) / 1000).toFixed(1);
      const ts = new Date().toISOString().slice(11, 19);
      if (err) {
        console.log(`[${ts}] ERROR (${elapsed}s): ${err.message}`);
      } else {
        const summary = stdout.trim().split("\n").pop();
        console.log(`[${ts}] ${summary} (${elapsed}s)`);
      }
      if (stderr) console.error(stderr.trim());
      running = false;
      resolve();
    });
  });
}

console.log("Starting poll loop (every 2 min). Ctrl+C to stop.");
console.log("Working directory:", path.join(__dirname, ".."));

// Run immediately, then on interval
await runOnce();
setInterval(runOnce, INTERVAL_MS);
