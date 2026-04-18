/* Autumn — chat client with voice, syntax highlighting, status bar */

let pin = "";
let token = localStorage.getItem("miette_token") || "";
let sending = false;
let listening = false;
let recognition = null;
let statusInterval = null;

// === Boot ===

document.addEventListener("DOMContentLoaded", () => {
  if (token) showChat();
  setupVoice();
  // Poll status every 5s — live updates
  statusInterval = setInterval(pollStatus, 5000);
});

// === Pin Gate ===

function pressKey(digit) {
  if (pin.length >= 4) return;
  pin += digit;
  updateDots();
  if (pin.length === 4) authenticate();
}

function pressBack() {
  pin = pin.slice(0, -1);
  updateDots();
  document.getElementById("pin-error").textContent = "";
}

function updateDots() {
  const dots = document.querySelectorAll("#pin-dots span");
  dots.forEach((dot, i) => dot.classList.toggle("filled", i < pin.length));
}

async function authenticate() {
  try {
    const resp = await fetch("/api/auth", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pin }),
    });
    if (!resp.ok) {
      document.getElementById("pin-error").textContent = "Wrong pin";
      pin = "";
      updateDots();
      shake();
      return;
    }
    const data = await resp.json();
    token = data.token;
    localStorage.setItem("miette_token", token);
    showChat();
  } catch {
    document.getElementById("pin-error").textContent = "Connection error";
    pin = "";
    updateDots();
  }
}

function shake() {
  const dots = document.getElementById("pin-dots");
  dots.style.animation = "none";
  dots.offsetHeight;
  dots.style.animation = "shake 0.4s ease";
}

// === Chat ===

function showChat() {
  document.getElementById("gate").classList.add("hidden");
  document.getElementById("chat").classList.remove("hidden");
  addSystemMessage("Connected to Autumn");
  document.getElementById("input").focus();
  pollStatus();
}

function addMessage(role, content, tool) {
  const displayRole = role === "assistant" ? "autumn" : role;
  const el = document.createElement("div");
  el.className = `msg ${displayRole}`;

  const time = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

  // Syntax highlight bluebook code blocks
  const formatted = highlightBluebook(escapeHtml(content));

  let toolBadge = "";
  if (tool) {
    const toolNames = {
      conceive_domain: "☀️ Summer",
      read_vitals: "💓 Vitals",
      list_domains: "📚 Domains",
      save_memory: "🧠 Memory",
      read_memory: "🧠 Memory",
      check_summer: "☀️ Summer",
      update_mood: "🌊 Mood",
    };
    toolBadge = `<span class="tool-badge">${toolNames[tool] || tool}</span>`;
  }

  el.innerHTML = toolBadge + formatted + `<span class="timestamp">${time}</span>`;

  const messages = document.getElementById("messages");
  messages.appendChild(el);
  messages.scrollTop = messages.scrollHeight;

  // Speak Miette's replies
  if (displayRole === "autumn" && window.speechSynthesis) {
    // Strip code blocks for speech
    const speakText = content.replace(/Hecks\.bluebook[\s\S]*?end/g, "domain conceived.").slice(0, 300);
    speak(speakText);
  }
}

function addSystemMessage(text) {
  const el = document.createElement("div");
  el.className = "msg system";
  el.textContent = text;
  document.getElementById("messages").appendChild(el);
}

function showTyping(text) {
  hideTyping();
  const el = document.createElement("div");
  el.className = "typing";
  el.id = "typing-indicator";
  el.textContent = text || "Autumn is thinking";
  const messages = document.getElementById("messages");
  messages.appendChild(el);
  messages.scrollTop = messages.scrollHeight;
}

function hideTyping() {
  const el = document.getElementById("typing-indicator");
  if (el) el.remove();
}

async function send() {
  if (sending) return;
  const input = document.getElementById("input");
  const content = input.value.trim();
  if (!content) return;

  input.value = "";
  input.style.height = "auto";
  sending = true;
  document.getElementById("send-btn").disabled = true;

  addMessage("user", content);
  showTyping("Autumn is thinking");

  try {
    const resp = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ content }),
    });

    hideTyping();

    if (resp.status === 401) {
      localStorage.removeItem("miette_token");
      token = "";
      location.reload();
      return;
    }

    if (!resp.ok) {
      addSystemMessage("Error: " + resp.status);
      return;
    }

    const data = await resp.json();
    addMessage("assistant", data.reply, data.tool);
  } catch {
    hideTyping();
    addSystemMessage("Connection lost");
  } finally {
    sending = false;
    document.getElementById("send-btn").disabled = false;
    input.focus();
  }
}

function handleKey(event) {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    send();
  }
}

function autoGrow(el) {
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight, 120) + "px";
}

async function logout() {
  try { await fetch("/api/logout", { headers: { Authorization: `Bearer ${token}` } }); } catch {}
  localStorage.removeItem("miette_token");
  token = "";
  location.reload();
}

// === Syntax highlighting for Bluebook ===

function highlightBluebook(html) {
  // Detect bluebook blocks and wrap in <pre>
  return html.replace(
    /(Hecks\.bluebook[\s\S]*?(?:\nend|\n.*end))/g,
    (match) => `<pre class="bluebook">${colorize(match)}</pre>`
  ).replace(
    /(aggregate |policy |value_object |command |vision |description |emits |given |reference_to|lifecycle |transition |workflow |step |glossary |define |prefer )/g,
    '<span class="kw">$1</span>'
  );
}

function colorize(code) {
  return code
    .replace(/\b(aggregate|policy|value_object|command|vision|description|emits|given|reference_to|lifecycle|transition|workflow|step|glossary|define|prefer|list_of|do|end|on|trigger|from|role|then_set|to|category)\b/g, '<span class="kw">$1</span>')
    .replace(/\b(String|Integer|Float|Boolean|Date|DateTime)\b/g, '<span class="type">$1</span>')
    .replace(/"([^"]*)"/g, '<span class="str">"$1"</span>')
    .replace(/(:\w+)/g, '<span class="sym">$1</span>')
    .replace(/(#.*)/g, '<span class="cmt">$1</span>');
}

// === Voice ===

function setupVoice() {
  if (!("webkitSpeechRecognition" in window || "SpeechRecognition" in window)) return;

  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  recognition = new SpeechRecognition();
  recognition.continuous = false;
  recognition.interimResults = false;
  recognition.lang = "en-US";

  recognition.onresult = (event) => {
    const text = event.results[0][0].transcript;
    document.getElementById("input").value = text;
    send();
  };

  recognition.onend = () => {
    listening = false;
    const btn = document.getElementById("voice-btn");
    if (btn) btn.classList.remove("active");
  };

  // Show voice button
  const voiceBtn = document.getElementById("voice-btn");
  if (voiceBtn) voiceBtn.classList.remove("hidden");
}

function toggleVoice() {
  if (!recognition) return;
  if (listening) {
    recognition.stop();
    listening = false;
  } else {
    recognition.start();
    listening = true;
    const btn = document.getElementById("voice-btn");
    if (btn) btn.classList.add("active");
  }
}

function speak(text) {
  if (!window.speechSynthesis) return;
  window.speechSynthesis.cancel();
  const utter = new SpeechSynthesisUtterance(text);
  utter.rate = 0.88;
  utter.pitch = 1.15;
  utter.volume = 0.9;
  // Pick a warm, natural voice — prefer Samantha (macOS/iOS), or any soft voice
  const voices = window.speechSynthesis.getVoices();
  const preferred = voices.find(v =>
    v.name.includes("Samantha") ||
    v.name.includes("Zoe") ||
    v.name.includes("Fiona") ||
    v.name.includes("Tessa") ||
    v.name.includes("Moira") ||
    (v.name.includes("Google") && v.name.includes("Female")) ||
    v.name.includes("Microsoft Aria")
  );
  if (preferred) utter.voice = preferred;
  window.speechSynthesis.speak(utter);
}

// Pre-load voices (needed on some browsers)
if (window.speechSynthesis) {
  window.speechSynthesis.getVoices();
  window.speechSynthesis.onvoiceschanged = () => window.speechSynthesis.getVoices();
}

// === Status bar ===

async function pollStatus() {
  if (!token) return;
  try {
    const resp = await fetch("/api/status");
    if (!resp.ok) return;
    const s = await resp.json();
    const el = document.getElementById("status-text");
    if (!el) return;

    const sep = '<span class="sep">·</span>';
    let line = "";

    if (s.state === "sleeping" && s.sleep) {
      const phase = s.sleep.phase || "sleeping";
      line = `<span class="state-sleeping">Autumn is sleeping</span>${sep}${phase}${sep}cycles: ${s.sleep.cycle || 0}${sep}dream pulses: ${s.sleep.dream_pulses || 0}${sep}beats: ${s.beats || 0}`;
    } else {
      line = `<span class="state-awake">Autumn is awake</span>${sep}mood: ${s.mood || "?"}${sep}beats: ${s.beats || 0}${sep}fatigue: ${s.fatigue || "?"}${sep}pulse: ${s.flow || "?"}${sep}since sleep: ${s.pulses_since_sleep || 0}`;
    }

    if (s.training) {
      line += `${sep}☀️ r${s.training.round} loss:${s.training.loss?.toFixed(3) || "?"}`;
    }

    if (s.domains) {
      line += `${sep}📚 ${s.domains}`;
    }

    el.innerHTML = line;
  } catch {}
}

// === Helpers ===

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

// Inject shake animation
const style = document.createElement("style");
style.textContent = `@keyframes shake { 0%,100%{transform:translateX(0)} 25%{transform:translateX(-8px)} 50%{transform:translateX(8px)} 75%{transform:translateX(-4px)} }`;
document.head.appendChild(style);
