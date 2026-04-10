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
const BEING_PROMPT = path.join(HECKS_HOME, "hecks_being", "winter", "system_prompt.md");
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
  mouseSGR: true,
});

// Chat log — scrollable
const chatBox = blessed.box({
  top: 0,
  left: 0,
  width: "100%",
  height: "100%-4",
  scrollable: true,
  alwaysScroll: true,
  scrollbar: { ch: "│", style: { fg: "cyan" } },
  mouse: true,
  tags: true,
  wrap: true,
  padding: { left: 1, right: 1 },
});

// Input box
const inputBox = blessed.textbox({
  bottom: 1,
  left: 0,
  width: "100%",
  height: 3,
  border: { type: "line" },
  style: {
    border: { fg: "green" },
    fg: "white",
  },
  inputOnFocus: true,
  keys: true,
  mouse: true,
  padding: { left: 1 },
});

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

// Thinking indicator — lower left, color-cycling
const thinkingBox = blessed.box({
  bottom: 1,
  left: 0,
  width: 30,
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

screen.append(chatBox);
screen.append(thinkingBox);
screen.append(inputBox);
screen.append(footer);

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

function updateFooter() {
  const branch = execSync(`git -C ${HECKS_HOME} branch --show-current 2>/dev/null`);
  const recent = getRecentDomains(3).join(" · ");
  footer.setContent(
    ` ${branch} │ ${nurseryCount} domains │ ❄ ${winterMood} │ ${winterBeats} beats │ ${recent}`
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
              const thought = (c.thinking || "").replace(/\n/g, " ").slice(0, 80);
              if (thought) appendChat(`{cyan-fg}  💭 ${thought}{/cyan-fg}`);
            } else if (c.type === "tool_use") {
              toolCount++;
              const name = c.name || "?";
              const inp = c.input || {};
              let detail = "";
              if (name === "Bash") detail = (inp.command || "").slice(0, 60);
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
              appendChat(`{${color}-fg}  🔧 ${label}{/${color}-fg}`);
            } else if (c.type === "text") {
              const text = (c.text || "").trim();
              if (text) response += (response ? "\n" : "") + c.text;
            }
          }
        } else if (j.type === "user") {
          const contents = (j.message || {}).content || [];
          for (const c of contents) {
            if (c.type === "tool_result") {
              const result = (c.content || "").replace(/\n/g, " ").slice(0, 70);
              const err = c.is_error ? " ⚠" : "";
              appendChat(`{white-fg}  ↩ ${result}${err}{/white-fg}`);
            }
          }
        }
      }
    });

    proc.on("close", () => {
      stopThinking();
      resolve({ response: response.trim(), tools: toolCount });
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

  // Focus input
  inputBox.focus();
  screen.render();

  // Input handler
  inputBox.on("submit", async (value) => {
    const input = value.trim();
    inputBox.clearValue();
    screen.render();

    if (!input) { inputBox.focus(); return; }
    if (input === "exit" || input === "quit") {
      shutdown();
      return;
    }

    if (input === "pulse") {
      const out = execSync(`ruby ${PULSE_SCRIPT} "pulse check" < /dev/null 2>&1`);
      appendChat(out);
      inputBox.focus();
      return;
    }

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
    nurseryCount = countNursery();
    updateFooter();

    const carrying = (input.split(/[.!?]/)[0] || input).slice(0, 40);
    pulse(carrying);

    inputBox.focus();
    screen.render();
  });
}

function shutdown() {
  screen.destroy();
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
screen.key(["escape"], () => { inputBox.focus(); screen.render(); });

main().catch((err) => {
  screen.destroy();
  console.error(err);
  process.exit(1);
});
