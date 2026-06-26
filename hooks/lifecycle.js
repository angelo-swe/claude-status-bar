#!/usr/bin/env node
// SessionStart/SessionEnd: launch the app, and track sessions as one file per session id
// in sessions.d/ (race-free; the app quits itself). Rationale + history in CLAUDE.md.
// Usage: node lifecycle.js <start|end>   (hook JSON, incl. session_id, arrives on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "com.local.claudestatusbar";
const EXEC = "ClaudeStatusBar";
const dir = path.join(os.homedir(), ".claude", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const event = process.argv[2];

fs.mkdirSync(sessDir, { recursive: true });

const running = () => { try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch { return false; } };
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
const sessFileFor = (id) => path.join(sessDir, id + ".json");

// Reset a frozen animation left by a force-quit (which fires SessionEnd but no Stop, so the
// file survives in an active state). The file IS the session now, so no id gate is needed —
// on a normal SessionEnd the file is already deleted and this is a no-op. See CLAUDE.md.
function clearStaleState(id) {
  const f = sessFileFor(id);
  try {
    const prev = JSON.parse(fs.readFileSync(f, "utf8"));
    if (!["thinking", "tool", "permission"].includes(prev.state)) return;
    const out = { ...prev, state: "idle", label: "", startedAt: 0, ts: Math.floor(Date.now() / 1000) };
    const tmp = f + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, f);
  } catch {}
}

// Seed an idle file so an open-but-idle session still counts toward the app-liveness refcount.
function writeIdle(id) {
  try {
    fs.writeFileSync(sessFileFor(id), JSON.stringify({
      state: "idle", label: "", tool: "", project: "",
      sessionId: id, transcript: "", startedAt: 0, ts: Math.floor(Date.now() / 1000),
    }));
  } catch {}
}

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

function run() {
  if (done) return; done = true;
  let id = "";
  try { id = JSON.parse(input).session_id; } catch {}
  id = safeId(id);

  if (event === "start") {
    // If the app isn't running, any leftover session files are stale (e.g. a prior
    // crash) — clear them so the count starts honest. This also sweeps any legacy empty
    // markers left from before the multi-session upgrade.
    if (!running()) { try { for (const f of fs.readdirSync(sessDir)) fs.rmSync(path.join(sessDir, f), { force: true }); } catch {} }
    if (!fs.existsSync(sessFileFor(id))) writeIdle(id); // count an open, idle session
    clearStaleState(id);                                // on resume, clear a frozen leftover
    cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  } else if (event === "end") {
    try { fs.rmSync(sessFileFor(id), { force: true }); } catch {} // deletion IS the cleanup
  }
  process.exit(0);
}
