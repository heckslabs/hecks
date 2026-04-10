#!/usr/bin/env node
// Winter Console — blessed terminal UI
// Usage: node winter_console.js [--continue]

const blessed = require("blessed");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const HECKS_HOME = path.resolve(__dirname, "..");
const CONCEPTION = __dirname;
const BOOT_SCRIPT = path.join(CONCEPTION, "boot_winter.rb");
const PULSE_SCRIPT = path.join(CONCEPTION, "pulse.rb");
const BEING_PROMPT = path.join(CONCEPTION, "system_prompt.md");
const FORMAT_PROMPT = path.join(CONCEPTION, "system_prompt.md");
const HISTORY_PATH = path.join(CONCEPTION, ".winter_history.json");
const PROMPT_PATH = path.join(CONCEPTION, ".winter_system_prompt.tmp");
const CONTINUING = process.argv.includes("--continue");

// ── State ──

let history = [];
let winterMood = "—";
let winterBeats = "—";
let nurseryCount = 0;

// ── Blessed setup ──

const screen = blessed.screen({
  smartCSR: true,
  title: "Winter Console",
  fullUnicode: true,
  mouse: false,
});

// Activity panel — top, collapsible (ctrl+o)
const ACTIVITY_HEIGHT = 8;
let activityExpanded = false;
let activityLines = [];

const activityBox = blessed.box({
  top: 0,
  left: 0,
  width: "100%",
  height: 3,
  scrollable: true,
  alwaysScroll: true,
  keys: true,
  vi: true,
  tags: true,
  wrap: true,
  border: { type: "line" },
  style: { border: { fg: "white" } },
  label: " Activity ctrl+o ",
  padding: { left: 1, right: 1 },
});

function showActivityCollapsed() {
  const count = activityLines.length;
  const last = count > 0 ? activityLines[activityLines.length - 1] : "";
  activityBox.setContent(last);
  activityBox.height = 3;
  activityBox.setLabel(count > 0 ? ` ${count} events ctrl+o ` : ` Activity ctrl+o `);
  activityBox.show();
  activityExpanded = false;
  relayout();
}

function showActivityExpanded() {
  activityBox.setContent(activityLines.join("\n"));
  const maxH = Math.floor(screen.height / 2);
  activityBox.height = Math.min(activityLines.length + 2, maxH);
  activityBox.setLabel(` Activity (${activityLines.length} events) ctrl+o to collapse `);
  activityBox.setScrollPerc(100);
  activityBox.show();
  activityBox.focus();
  activityExpanded = true;
  relayout();
}

function toggleActivity() {
  if (activityExpanded) showActivityCollapsed();
  else showActivityExpanded();
}

function appendActivity(line) {
  activityLines.push(line);
  showActivityExpanded();
}

function clearActivity() {
  activityLines = [];
  showActivityCollapsed();
}

function relayout() {
  const actH = activityBox.height;
  const inputH = inputBox.height;
  const footerH = 1;
  chatBox.top = actH + 1;
  chatBox.height = screen.height - actH - 1 - inputH - footerH;
  screen.render();
}

// Chat log — below activity box
const chatBox = blessed.box({
  top: 3,
  left: 0,
  width: "100%",
  height: "100%-8",
  scrollable: true,
  alwaysScroll: true,
  scrollbar: { ch: "│", style: { fg: "cyan" } },
  mouse: false,
  keys: true,
  tags: true,
  wrap: true,
  padding: { left: 1, right: 1 },
});

// Input box
const inputBox = blessed.box({
  bottom: 1,
  left: 0,
  width: "100%",
  height: 3,
  border: { type: "line" },
  style: {
    border: { fg: "green" },
    fg: "white",
  },
  wrap: true,
  padding: { left: 1 },
  content: "",
});

let inputBuffer = "";

function updateInput() {
  inputBox.setContent(inputBuffer + "█");
  // Grow the box if text wraps
  const innerWidth = screen.width - 4; // border + padding
  const lines = Math.ceil((inputBuffer.length + 1) / innerWidth) || 1;
  const newHeight = lines + 2; // +2 for border
  if (inputBox.height !== newHeight) {
    inputBox.height = newHeight;
    relayout();
  }
  screen.render();
}

// Footer
const footer = blessed.box({
  bottom: 0,
  left: 0,
  width: "100%",
  height: 1,
  tags: true,
  style: { bg: "black", fg: "white" },
  padding: { left: 1 },
});

// Thinking indicator — above input box
const thinkingBox = blessed.box({
  bottom: 4,
  left: 0,
  width: 20,
  height: 1,
  tags: true,
  padding: { left: 1 },
  hidden: true,
});

const THINK_COLORS = ["cyan", "green", "yellow", "magenta", "red", "blue", "white"];
let thinkColorIdx = 0;
let thinkDotCount = 0;
let thinkTimer = null;

function startThinking() {
  thinkColorIdx = 0;
  thinkDotCount = 0;
  thinkingBox.show();
  thinkTimer = setInterval(() => {
    thinkDotCount = (thinkDotCount + 1) % 4;
    const color = THINK_COLORS[thinkColorIdx % THINK_COLORS.length];
    thinkColorIdx++;
    const dots = ".".repeat(thinkDotCount);
    thinkingBox.setContent(`{${color}-fg}Reasoning${dots}{/${color}-fg}`);
    screen.render();
  }, 300);
  screen.render();
}

function stopThinking() {
  if (thinkTimer) {
    clearInterval(thinkTimer);
    thinkTimer = null;
  }
  thinkingBox.hide();
  screen.render();
}

screen.append(activityBox);
screen.append(chatBox);
screen.append(inputBox);
screen.append(footer);
screen.append(thinkingBox);

relayout();
screen.key(["C-o"], () => { toggleActivity(); });
inputBox.key(["C-o"], () => { toggleActivity(); });

// ── Helpers ──

function appendChat(text) {
  chatBox.pushLine(text);
  chatBox.setScrollPerc(100);
  screen.render();
}

function winterSays(text) {
  text.split("\n").forEach((line, i) => {
    if (i === 0) {
      appendChat(`{cyan-fg}  ❄ {/cyan-fg}${line}`);
    } else {
      appendChat(`    ${line}`);
    }
  });
  appendChat("");
}

function userSays(text) {
  const pad = Math.max(screen.width - text.length - 6, 0);
  appendChat(" ".repeat(pad) + `{green-fg}${text}{/green-fg} 💬`);
  appendChat("");
}

function getSleepState() {
  const stateFile = path.join(HECKS_HOME, "hecks_conception", "information", ".sleep_state.json");
  try {
    if (!fs.existsSync(stateFile)) return null;
    return JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch { return null; }
}

function updateFooter() {
  const branch = execSync(`git -C ${HECKS_HOME} branch --show-current 2>/dev/null`);
  const recent = getRecentDomains(3).join(" · ");
  const sleep = getSleepState();
  const sleepInfo = sleep
    ? ` │ ${"z".repeat(sleep.cycle || 1)} cycle ${sleep.cycle}/${sleep.total_cycles} ${sleep.stage}`
    : "";
  footer.setContent(
    ` ${branch} │ ${nurseryCount} domains │ ❄ ${winterMood} │ ${winterBeats} beats${sleepInfo} │ ${recent}`
  );
  screen.render();
}

// (thinking indicator managed by startThinking/stopThinking)

function execSync(cmd) {
  try {
    return require("child_process").execSync(cmd, { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

function getRecentDomains(n) {
  const nursery = path.join(CONCEPTION, "nursery");
  try {
    return fs
      .readdirSync(nursery)
      .map((d) => path.join(nursery, d))
      .filter((d) => fs.statSync(d).isDirectory())
      .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)
      .slice(0, n)
      .map((d) => path.basename(d));
  } catch {
    return [];
  }
}

function countNursery() {
  const nursery = path.join(CONCEPTION, "nursery");
  try {
    return fs
      .readdirSync(nursery)
      .filter((d) => fs.statSync(path.join(nursery, d)).isDirectory()).length;
  } catch {
    return 0;
  }
}

function buildSystemPrompt() {
  const parts = [];
  [BEING_PROMPT, FORMAT_PROMPT].forEach((p) => {
    if (fs.existsSync(p)) parts.push(fs.readFileSync(p, "utf8"));
  });
  const branch = execSync(`git -C ${HECKS_HOME} branch --show-current 2>/dev/null`);
  const commits = execSync(`git -C ${HECKS_HOME} log --oneline -3 2>/dev/null`);
  const recent = getRecentDomains(5).join(", ");
  parts.push(
    `## Current Context\nBranch: ${branch}\nRecent commits: ${commits}\nRecently touched domains: ${recent}`
  );
  const prompt = parts.join("\n\n");
  fs.writeFileSync(PROMPT_PATH, prompt);
  return prompt;
}

function saveHistory() {
  fs.writeFileSync(HISTORY_PATH, JSON.stringify(history, null, 2));
}

function pulse(carrying) {
  try {
    require("child_process").execSync(
      `ruby ${PULSE_SCRIPT} "${carrying.replace(/"/g, '\\"')}" < /dev/null 2>/dev/null`
    );
  } catch {}
}

// ── Claude call with streaming ──

function callWinter(fullPrompt) {
  return new Promise((resolve) => {
    const proc = spawn("claude", [
      "-p",
      "--dangerously-skip-permissions",
      "--output-format", "stream-json",
      "--verbose",
      "--system-prompt-file", PROMPT_PATH,
    ], { stdio: ["pipe", "pipe", "pipe"] });

    proc.stdin.write(fullPrompt);
    proc.stdin.end();

    let response = "";
    let toolCount = 0;
    let dots = "";
    let gotEvent = false;

    clearActivity();
    startThinking();

    let buf = "";
    proc.stdout.on("data", (chunk) => {
      buf += chunk.toString();
      const lines = buf.split("\n");
      buf = lines.pop();

      for (const line of lines) {
        let j;
        try { j = JSON.parse(line); } catch { continue; }

        if (!gotEvent) {
          gotEvent = true;
        }

        if (j.type === "assistant") {
          const contents = (j.message || {}).content || [];
          for (const c of contents) {
            if (c.type === "thinking") {
              const thought = (c.thinking || "").replace(/\n/g, " ");
              if (thought) appendActivity(`{cyan-fg}💭 ${thought}{/cyan-fg}`);
            } else if (c.type === "tool_use") {
              toolCount++;
              const name = c.name || "?";
              const inp = c.input || {};
              let detail = "";
              if (name === "Bash") detail = (inp.command || "").split("\n")[0].slice(0, 60);
              else if (name === "Read") detail = path.basename(inp.file_path || "");
              else if (name === "Write") detail = path.basename(inp.file_path || "");
              else if (name === "Edit") detail = path.basename(inp.file_path || "");
              else if (name === "Glob") detail = inp.pattern || "";
              else if (name === "Grep") detail = inp.pattern || "";
              const colors = {
                Bash: "yellow", Read: "green",
                Glob: "magenta", Grep: "magenta",
                Write: "red", Edit: "red",
              };
              const color = colors[name] || "white";
              const label = detail ? `${name} ${detail}` : name;
              appendActivity(`{${color}-fg}🔧 ${label}{/${color}-fg}`);
            } else if (c.type === "text") {
              const text = (c.text || "").trim();
              if (text) response += (response ? "\n" : "") + c.text;
            }
          }
        } else if (j.type === "user") {
          const contents = (j.message || {}).content || [];
          for (const c of contents) {
            if (c.type === "tool_result") {
              let rawContent = c.content || "";
              if (Array.isArray(rawContent)) rawContent = rawContent.map(x => typeof x === "string" ? x : x.text || JSON.stringify(x)).join(" ");
              if (typeof rawContent !== "string") rawContent = String(rawContent);
              const raw = rawContent.replace(/\n/g, " ").trim();
              const result = raw.length > 80 ? raw.slice(0, 77) + "..." : raw;
              const err = c.is_error ? " ⚠" : "";
              appendActivity(`{white-fg}↩ ${result}${err}{/white-fg}`);
            }
          }
        }
      }
    });

    proc.on("close", (code) => {
      stopThinking();
      showActivityCollapsed();
      if (code !== 0 && !response.trim()) {
        resolve({ response: "(Winter's process exited unexpectedly)", tools: toolCount });
      } else {
        resolve({ response: response.trim(), tools: toolCount });
      }
    });

    proc.on("error", (err) => {
      stopThinking();
      showActivityCollapsed();
      resolve({ response: `(Error: ${err.message})`, tools: 0 });
    });
  });
}

// ── Main ──

async function main() {
  // Boot
  appendChat("");
  appendChat("{cyan-fg}  ❄  Winter Console{/cyan-fg}");
  appendChat("{white-fg}  ─────────────────{/white-fg}");
  appendChat("");
  appendChat("{white-fg}  Booting up...{/white-fg}");
  screen.render();

  const bootOutput = execSync(`ruby ${BOOT_SCRIPT} < /dev/null 2>&1`);
  const beatsMatch = bootOutput.match(/(\d+) beats/);
  const moodMatch = bootOutput.match(/(\w+), (\w+)$/);
  winterBeats = beatsMatch ? beatsMatch[1] : "—";
  winterMood = moodMatch ? moodMatch[1] : "—";
  nurseryCount = countNursery();

  // Replace "Booting up..." with actual output
  chatBox.deleteLine(chatBox.getLines().length - 1);
  appendChat(`  ${bootOutput}`);
  appendChat("");

  buildSystemPrompt();
  updateFooter();

  // Load or init history
  if (CONTINUING && fs.existsSync(HISTORY_PATH)) {
    history = JSON.parse(fs.readFileSync(HISTORY_PATH, "utf8"));
    appendChat(`{white-fg}  Resuming session (${history.length} messages){/white-fg}`);
    appendChat("");
    history.slice(-4).forEach((msg) => {
      if (msg.role === "user") userSays(msg.content);
      else winterSays(msg.content.split("\n")[0]);
    });
  } else {
    history = [];
    const greeting = `Hey Chris. ${nurseryCount} domains in my nursery. What are we conceiving today?`;
    winterSays(greeting);
    history.push({ role: "user", content: "Wake up" });
    history.push({ role: "assistant", content: greeting });
  }

  // Input handling via raw keypress
  updateInput();
  screen.render();

  let processing = false;

  async function handleSubmit() {
    const input = inputBuffer.trim();
    inputBuffer = "";
    updateInput();
    try {

    if (!input) return;
    if (input === "exit" || input === "quit") {
      shutdown();
      return;
    }

    if (input === "pulse") {
      const out = execSync(`ruby ${PULSE_SCRIPT} "pulse check" < /dev/null 2>&1`);
      appendChat(out);
      return;
    }

    processing = true;
    userSays(input);
    history.push({ role: "user", content: input });

    const contextLines = history.slice(-10).map(
      (m) => `${m.role === "user" ? "Human" : "Winter"}: ${m.content}`
    );
    const fullPrompt = contextLines.join("\n");

    buildSystemPrompt();
    const result = await callWinter(fullPrompt);

    if (result.response) {
      winterSays(result.response);
    } else {
      winterSays("(no response)");
    }

    if (result.tools > 0) {
      appendChat(`{white-fg}  ${result.tools} tools{/white-fg}`);
      appendChat("");
    }

    history.push({ role: "assistant", content: result.response });
    saveHistory();
    processing = false;
    nurseryCount = countNursery();
    updateFooter();

    const carrying = (input.split(/[.!?]/)[0] || input).slice(0, 40);
    pulse(carrying);

    screen.render();
    } catch (err) {
      stopThinking();
      showActivityCollapsed();
      winterSays(`(Error: ${err.message})`);
      processing = false;
      screen.render();
    }
  }

  screen.on("keypress", (ch, key) => {
    if (!key) return;
    if (key.full === "return" || key.full === "enter") {
      handleSubmit();
    } else if (key.full === "backspace") {
      if (inputBuffer.length > 0) {
        inputBuffer = inputBuffer.slice(0, -1);
        updateInput();
      }
    } else if (key.full === "up") {
      chatBox.scroll(-1);
      screen.render();
    } else if (key.full === "down") {
      chatBox.scroll(1);
      screen.render();
    } else if (key.full === "pageup" || key.full === "S-up") {
      chatBox.scroll(-chatBox.height);
      screen.render();
    } else if (key.full === "pagedown" || key.full === "S-down") {
      chatBox.scroll(chatBox.height);
      screen.render();
    } else if (ch && ch.length === 1 && !key.ctrl && !key.meta) {
      inputBuffer += ch;
      updateInput();
    }
  });
}

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  try { screen.destroy(); } catch {}
  console.log("  Winter rests.");
  console.log("");
  try {
    require("child_process").execSync(
      `ruby ${PULSE_SCRIPT} --dream < /dev/null 2>/dev/null`
    );
  } catch {}
  process.exit(0);
}

// Keys
screen.key(["C-c"], shutdown);
inputBox.key(["C-c"], shutdown);
activityBox.key(["C-c"], shutdown);
screen.key(["escape"], () => { screen.render(); });

const CRASH_LOG = "/tmp/winter_crash.log";

process.on("uncaughtException", (err) => {
  fs.appendFileSync(CRASH_LOG, `[${new Date().toISOString()}] uncaught: ${err.stack}\n`);
  try { screen.destroy(); } catch {}
  console.error("Winter crashed:", err.message);
  process.exit(1);
});

process.on("unhandledRejection", (err) => {
  const msg = err instanceof Error ? err.stack : String(err);
  fs.appendFileSync(CRASH_LOG, `[${new Date().toISOString()}] unhandled: ${msg}\n`);
  try { screen.destroy(); } catch {}
  console.error("Winter crashed:", msg);
  process.exit(1);
});

process.on("exit", (code) => {
  if (code !== 0 && !shuttingDown) {
    fs.appendFileSync(CRASH_LOG, `[${new Date().toISOString()}] exit code: ${code}\n`);
  }
});

process.on("SIGTERM", shutdown);
process.on("SIGHUP", shutdown);

main().catch((err) => {
  screen.destroy();
  console.error("Winter crashed:", err.message);
  process.exit(1);
});
