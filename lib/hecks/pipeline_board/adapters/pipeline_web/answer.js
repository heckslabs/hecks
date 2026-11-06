// The answer prompt every board page shares: it shows what a blocked session said and sends your
// reply. A session with an AgentRun is answered through it (`answer`); any other blocked session is
// replied to directly (`reply`). Both go to POST /api/act, the board's one write.
//
// boardAnswer.open(sessions, pickId, hooks) opens it on the session with id `pickId` (a picker shows
// when there are several). `sessions` are the board's session rows. The hooks are optional:
// `sending(session, text)`, `sent(session)` and `failed(session, text, message)`. With
// `{ prefill: true }` the answer box starts with the reply Claude Code suggested for the session.
(function () {
  const STYLE = `
dialog.board-answer { width: min(40rem, 92vw); border: 1px solid var(--axis); border-radius: 10px; background: var(--surface);
  color: var(--ink); padding: 16px; }
dialog.board-answer::backdrop { background: rgba(0,0,0,.4); }
dialog.board-answer h2 { font-size: 15px; margin: 0 0 8px; text-transform: none; letter-spacing: 0; color: var(--ink); }
dialog.board-answer textarea { width: 100%; font: inherit; color: var(--ink); background: var(--page); border: 1px solid var(--axis);
  border-radius: 6px; padding: 6px 8px; resize: vertical; }
dialog.board-answer select { font: inherit; color: var(--ink); background: var(--page); border: 1px solid var(--axis); border-radius: 6px;
  padding: 3px 6px; max-width: 100%; margin-bottom: 8px; }
dialog.board-answer .key, dialog.board-answer .hint { color: var(--ink2); font-size: 12px; }
dialog.board-answer .question { border-left: 4px solid var(--warning, var(--you)); padding: 6px 10px; margin: 8px 0; background: var(--page);
  border-radius: 0 6px 6px 0; overflow-wrap: anywhere; max-height: 46vh; overflow: auto; }
dialog.board-answer .label { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: var(--ink2); margin-bottom: 4px; }
dialog.board-answer .md p { margin: 0 0 8px; } dialog.board-answer .md ul { margin: 0 0 8px; padding-left: 20px; }
dialog.board-answer .md code { font-family: ui-monospace, Menlo, monospace; font-size: 12px; background: var(--surface); padding: 1px 4px;
  border-radius: 4px; }
dialog.board-answer .md pre.code { background: var(--surface); border: 1px solid var(--axis); border-radius: 6px; padding: 8px;
  margin: 0 0 8px; overflow-x: auto; }
dialog.board-answer .md pre.code code { background: none; padding: 0; white-space: pre; display: block; }
dialog.board-answer .more { margin: 4px 0; font-size: 12px; } dialog.board-answer ol.steps { margin: 4px 0 0 18px; padding: 0; }
dialog.board-answer .actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 10px; }
dialog.board-answer .actions button { font: inherit; color: var(--ink); background: var(--surface); border: 1px solid var(--axis);
  border-radius: 6px; padding: 4px 12px; cursor: pointer; }
dialog.board-answer .actions button.send { background: var(--warning, var(--you)); border-color: transparent; color: #111; font-weight: 600; }
dialog.board-answer .actions button:disabled { opacity: .5; }
dialog.board-answer .needs { margin: 0 0 6px; font-weight: 600; }
dialog.board-answer .suggest { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin: 8px 0 4px; }
dialog.board-answer .suggest button { font: inherit; font-size: 13px; text-align: left; color: var(--ink); background: var(--page);
  border: 1px dashed var(--warning, var(--you)); border-radius: 999px; padding: 3px 12px; cursor: pointer; max-width: 100%;
  overflow-wrap: anywhere; }
dialog.board-answer .suggest button:hover { border-style: solid; }
dialog.board-answer .status { min-height: 1.4em; font-size: 12px; color: var(--ink2); margin-top: 6px; }`;

  function h(tag, attrs, ...kids) {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) if (v !== null && v !== undefined && v !== false) n.setAttribute(k, v);
    for (const k of kids.flat(Infinity)) if (k !== null && k !== undefined && k !== false) n.append(k);
    return n;
  }

  // Markdown built as DOM nodes, never raw HTML: paragraphs, bullet lists, **bold**, `inline code`
  // and fenced code blocks, which keep their line breaks and monospace type.
  function inline(text) {
    const nodes = [], re = /(`[^`\n]+`|\*\*(?:[^*\n]|\*(?!\*))+\*\*)/g;
    let last = 0, m;
    while ((m = re.exec(text))) {
      if (m.index > last) nodes.push(text.slice(last, m.index));
      const t = m[0];
      nodes.push(t.startsWith("`") ? h("code", {}, t.slice(1, -1)) : h("b", {}, ...inline(t.slice(2, -2))));
      last = re.lastIndex;
    }
    if (last < text.length) nodes.push(text.slice(last).replace(/\*\*|`/g, ""));
    return nodes;
  }
  function markdown(text) {
    const out = [], lines = String(text || "").split("\n");
    let para = [], list = null;
    const flush = () => { if (para.length) { out.push(h("p", {}, ...inline(para.join(" ")))); para = []; } };
    const endList = () => { if (list) { out.push(h("ul", {}, ...list)); list = null; } };
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.trim().startsWith("```")) {
        flush(); endList();
        const code = [];
        for (i++; i < lines.length && !lines[i].trim().startsWith("```"); i++) code.push(lines[i]);
        out.push(h("pre", { class: "code" }, h("code", {}, code.join("\n"))));
      } else if (/^\s*[-*] /.test(line)) {
        flush(); list = list || [];
        list.push(h("li", {}, ...inline(line.replace(/^\s*[-*] /, ""))));
      } else if (line.trim() === "") { flush(); endList(); } else { endList(); para.push(line.trim()); }
    }
    flush(); endList();
    return out;
  }

  // Whether a question offers several solutions: two or more list items, or words that say so.
  const CHOICE_ITEM = /^\s*(?:[-*•]|\d+[.)]|\(?[a-d][.)])\s+\S/gm;
  const CHOICE_WORDS = /\b(options?|alternatives?|approach(?:es)?|which (?:one|do you|would you))\b/i;
  const offersChoices = (t) => (String(t || "").match(CHOICE_ITEM) || []).length >= 2 || CHOICE_WORDS.test(String(t || ""));

  let dialog = null, list = [], hooks = {};
  const $ = (sel) => dialog.querySelector(sel);
  const current = () => list[Number($(".pick").value)] || list[0];
  const said = (s) => (s.context && s.context.said) || s.question || s.detail;
  const answerable = (s) => Boolean(s.run || s.id);

  function build() {
    document.head.append(h("style", {}, STYLE));
    dialog = h("dialog", { class: "board-answer", "aria-labelledby": "board-answer-title" },
      h("h2", { id: "board-answer-title" }, "Answer a session waiting on you"),
      h("select", { class: "pick", "aria-label": "Session waiting on you" }),
      h("div", { class: "key" }), h("div", { class: "body" }),
      h("label", { for: "board-answer-text", class: "hint" }, "Your answer"),
      h("textarea", { id: "board-answer-text", rows: "4" }),
      h("div", { class: "status", "aria-live": "polite" }),
      h("div", { class: "actions" },
        h("button", { type: "button", class: "cancel", "data-tip": "Close without sending" }, "Cancel"),
        h("button", { type: "button", class: "yourcall", hidden: "", "data-tip": "Hand the choice back to the agent: sends \"your call\"" }, "Your call"),
        h("button", { type: "button", class: "send", "data-tip": "Send your answer (Enter sends, Shift+Enter adds a line)" }, "Send")));
    document.body.append(dialog);
    $(".pick").addEventListener("change", show);
    $(".cancel").addEventListener("click", () => dialog.close());
    $(".send").addEventListener("click", () => send());
    $(".yourcall").addEventListener("click", () => send("your call"));
    $("textarea").addEventListener("keydown", (e) => {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing) return;
      e.preventDefault();
      if (!$(".send").disabled) send();
    });
  }

  function show() {
    const s = current(), ctx = s.context || {};
    $(".key").textContent = [s.id && "Session " + s.id, s.name, s.agent, s.work_item && "work item " + s.work_item, s.run && "run " + s.run]
      .filter(Boolean).join(" · ");
    const needs = ctx.needs ? h("div", { class: "needs" }, "Needs: " + ctx.needs) : null;
    const parts = [h("div", { class: "question md" }, h("div", { class: "label" }, "Waiting on you"), needs, ...markdown(said(s)))];
    if ((ctx.did || []).length) parts.push(h("details", { class: "more" }, h("summary", {}, "Last steps (" + ctx.did.length + ")"),
      h("ol", { class: "steps" }, ctx.did.map((d) => h("li", {}, d)))));
    if (ctx.branch) parts.push(h("div", { class: "more" }, h("b", {}, "Branch: "), h("code", {}, ctx.branch)));
    if (ctx.suggested) {
      const use = h("button", { type: "button", "data-tip": "Put this reply in the answer box; Enter sends it" }, ctx.suggested);
      use.addEventListener("click", () => fill(s));
      parts.push(h("div", { class: "suggest" }, h("span", { class: "label" }, "Suggested reply"), use));
    }
    $(".body").replaceChildren(...parts);
    $(".send").disabled = !answerable(s);
    $(".yourcall").hidden = !answerable(s) || !offersChoices(said(s));
    $(".status").textContent = answerable(s) ? "" : "This session cannot be answered from the board.";
  }

  // Puts the session's suggested reply in the answer box, ready to send or edit.
  function fill(s) {
    const box = $("textarea");
    box.value = (s.context && s.context.suggested) || "";
    box.focus();
    box.setSelectionRange(box.value.length, box.value.length);
  }

  async function send(fixed) {
    const s = current(), text = (fixed || $("textarea").value).trim(), button = $(".send");
    if (!s || !answerable(s)) return;
    if (!text) { $(".status").textContent = "Write an answer first."; return; }
    button.disabled = true; $(".status").textContent = "Sending…";
    if (hooks.sending) hooks.sending(s, text);
    try {
      const body = { action: s.run ? "answer" : "reply", target: s.run || s.id, text };
      const res = await fetch("/api/act", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const answer = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(answer.error || "HTTP " + res.status);
      $("textarea").value = "";
      dialog.close();
      if (hooks.sent) hooks.sent(s);
    } catch (e) {
      $(".status").textContent = "Not sent: " + e.message;
      if (hooks.failed) hooks.failed(s, text, e.message);
    } finally { button.disabled = false; }
  }

  window.boardAnswer = {
    open(sessions, pickId, given, options) {
      if (!dialog) build();
      list = sessions; hooks = given || {};
      $(".pick").replaceChildren(...list.map((s, i) => h("option", { value: String(i) }, s.name + (s.work_item ? " · " + s.work_item : ""))));
      $(".pick").value = String(Math.max(0, list.findIndex((s) => s.id === pickId)));
      $(".pick").hidden = list.length < 2;
      $("textarea").value = "";
      show();
      dialog.showModal();
      if (options && options.prefill) fill(current());
      else $("textarea").focus();
    },
    markdown
  };
})();
