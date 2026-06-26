#!/usr/bin/env node
// Invoked by Claude Code hooks. Reads the hook JSON payload on stdin, maps the
// event to a status, and atomically writes one file per session at
// ~/.claude/statusbar/sessions.d/<session_id>.json (the app aggregates them all).
// Usage: node update.js <prompt|pre|post|notify|permreq|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".claude", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const event = process.argv[2] || "";
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);

// Claude Code writes an auto-generated "ai-title" into the session transcript — the same
// human-friendly name shown on the terminal tab. Tail the end of the transcript to grab the
// latest one cheaply (no full-file read; transcripts can be many MB).
function readAiTitle(tp) {
  if (!tp) return "";
  try {
    const fd = fs.openSync(tp, "r");
    const size = fs.fstatSync(fd).size;
    const start = size > 65536 ? size - 65536 : 0;
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    let title = "";
    for (const line of buf.toString("utf8").split("\n")) {
      if (line.indexOf('"ai-title"') === -1) continue; // cheap pre-filter before JSON.parse
      try { const j = JSON.parse(line); if (j.type === "ai-title" && j.aiTitle) title = j.aiTitle; } catch {}
    }
    return title;
  } catch { return ""; }
}

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  TodoWrite: "Planning",
};

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // Off by default; CLAUDE_STATUSBAR_DEBUG=1 logs every hook invocation to hooks.log.
  if (process.env.CLAUDE_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.appendFileSync(path.join(dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} msg=${JSON.stringify(p.message || "").slice(0, 160)} keys=${Object.keys(p).join(",")}\n`);
    } catch {}
  }

  const sid = safeId(p.session_id) || "unknown";
  const sessFile = path.join(sessDir, sid + ".json");

  // Read THIS session's previous state (per-session now, not the old single global file)
  // to preserve startedAt/transcript/project across hook calls within a turn. The
  // per-session transcript is load-bearing for denied-permission recovery — see CLAUDE.md.
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(sessFile, "utf8")); } catch {}

  // Register the session on ANY activity (even an unhandled event), so a session that
  // predates the hook install (never fired SessionStart) still counts toward the app's
  // liveness refcount and renders. Seed an idle file if none exists yet.
  try {
    fs.mkdirSync(sessDir, { recursive: true });
    if (!fs.existsSync(sessFile)) {
      fs.writeFileSync(sessFile, JSON.stringify({
        state: "idle", label: "", tool: "", project: prev.project || "", title: prev.title || "",
        sessionId: p.session_id || "", transcript: prev.transcript || "",
        startedAt: 0, ts: Math.floor(Date.now() / 1000),
      }));
    }
  } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  // Cache the title once found (it's stable) so we don't tail the transcript on every event.
  const title = prev.title || readAiTitle(p.transcript_path) || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "", startedAt = prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…"; startedAt = ts; break;
    case "pre": {
      const t = p.tool_name || "";
      // Known tools get a friendly verb; everything else (incl. long mcp__server__method
      // names) collapses to a generic "Using tool".
      state = "tool"; label = TOOL_LABELS[t] || "Using tool";
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      break;
    case "notify": {
      // Only a permission prompt drives the icon here (CLI path; desktop uses permreq). Ignore
      // every other Notification (esp. the idle_prompt "Claude is waiting for your input") so the
      // icon rests instead of parking on a confusing "Waiting for you". See CLAUDE.md.
      const m = (p.message || "").toLowerCase();
      const isPerm = p.notification_type === "permission_prompt" ||
        m.includes("permission") || m.includes("approve") || m.includes("allow");
      if (!isPerm) return;
      state = "permission"; label = "Awaiting permission"; startedAt = 0;
      break;
    }
    case "permreq":
      // Desktop-app permission signal; not redundant with notify (that's CLI-only). See CLAUDE.md.
      state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop":
      state = "done"; label = "Done"; startedAt = 0; break;
    default:
      return;
  }

  const out = { state, label, tool: p.tool_name || "", project, title, sessionId: p.session_id || "", transcript: p.transcript_path || prev.transcript || "", startedAt, ts };
  try {
    fs.mkdirSync(sessDir, { recursive: true });
    const tmp = sessFile + "." + process.pid + ".tmp"; // .tmp suffix is ignored by the app
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, sessFile);
  } catch {}
});
