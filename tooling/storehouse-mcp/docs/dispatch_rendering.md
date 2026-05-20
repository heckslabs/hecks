# Dispatch Rendering — `content[0].text`

The MCP `storehouse__dispatch` tool returns two surfaces : a
machine-readable `structuredContent` (events[], state, auto_summary,
stdout, stderr) and a human-readable `content[0].text`. This doc
shows what the human-readable surface looks like.

The renderer lives in `src/defs/cli/dispatch_render.mjs`. It composes
six sections, in order :

1. **Headline** — one line. Status icon (`✓` ok, `⚠` warn, `✗` fail),
   verb, exit code, event/policy/adapter/cascade counts, wall-clock
   duration in ms.
2. **Failure block** — only when `ok=false`. Surfaces the actual
   stderr line, the dispatch error, and any adapter failure cause so
   the failure mode reads at a glance.
3. **Timeline tree** — indented box-drawing of the cascade. One
   group per invocation_id. `├─` / `└─` box-drawing chars ; `⇢` for
   policy→dispatched arrows ; `📞` for adapter calls.
4. **State block** — flat list of the post-dispatch aggregate
   attributes (the trailing state JSON's nested aggregate snapshot).
   Lists/objects are summarised as `[N items]` / `{k1, k2, …}` so the
   block stays compact.
5. **Auto-summary** — the existing one-liner from
   `dispatch_digest.composeAutoSummary`, set off below the timeline
   with a leading `—` as the TL;DR.
6. **Raw appendix** — only when the digest didn't recognise every
   meaningful stdout line (e.g. the `[tts:elevenlabs]` adapter family
   the parser doesn't yet catch). Caps at 12 lines.

No ANSI colors. The MCP transport surfaces this as text, not a TTY,
so escape sequences would display as literal `\x1b[32m` garbage.
Unicode box-drawing + emoji-style glyphs render fine in every
terminal Chris uses.

The `structuredContent` stays byte-identical — this renderer only
shapes `content[0].text`. Old callers that consume the raw stdout
keep working via `structuredContent.stdout`.

---

## Sample 1 — Simple success (`Tools::ShellTool.Bash`)

A vanilla shell adapter dispatch. One event, one adapter call, no
policies. The headline reports `1 event · 1 adapter`; the timeline
shows the event leaf and the phone-icon adapter leaf under the
single invocation root.

```
✓ Tools::ShellTool.Bash · exit 0 · 1 event · 1 adapter · 124 ms

Timeline
ShellTool.Bash#inv_a1
├─ event ShellTool.BashRan#cli-smoke-bash
└─ 📞 claude_tool:bash ✓ exit=0

State (ShellTool)
  id="cli-smoke-bash"
  shell_command="echo hi"
  output="hi"
  exit_code=0
  ok=true

— Tools::ShellTool.Bash → exit 0, 1 event (BashRan), 0 policies fired
```

---

## Sample 2 — Cascade (`Round.StartRound` → policy → `RunGrowth`)

A policy-driven cascade. The first dispatch emits `RoundStarted`,
the `GrowOnStart` policy fires and dispatches `RunGrowth`, which
emits `GrowthComplete`. The renderer groups events by
`invocation_id`, so both invocations appear as siblings — the
policy arrow (`⇢`) shows the hand-off between them.

```
✓ Round::Round.StartRound · exit 0 · 2 events · 1 policy · 412 ms

Timeline
Round.StartRound#inv_r1
├─ event Round.RoundStarted#6
└─ policy GrowOnStart ⇢ RunGrowth

Round.RunGrowth#inv_r2
└─ event Round.GrowthComplete#6

State (Round)
  id="6"
  stage="growth"

— Round::Round.StartRound → exit 0, 2 events (RoundStarted, GrowthComplete), 1 policy (GrowOnStart) fired
```

---

## Sample 3 — Failure (unknown command)

A dispatch that never starts — bogus FQN, no aggregates root match.
Exit code 2, no events emitted. The headline shows `✗`, the failure
block surfaces the actual stderr line, and the auto-summary
mirrors the dispatch-did-not-start shape from the digest.

```
✗ Nope::Nope.NoSuchThing · exit 2 · 0 events · 38 ms

✗ dispatch failed
  stderr : Error: unknown command Nope::Nope.NoSuchThing in aggregates root /x

— Nope::Nope.NoSuchThing → dispatch did not start: Error: unknown command Nope::Nope.NoSuchThing in aggregates root /x
```

---

## Reproducing

The samples above are byte-identical to the output of :

```
node tooling/storehouse-mcp/test/dispatch_render_samples.mjs
```

That script feeds the renderer hand-crafted result objects (the
shape `dispatch.mjs` builds for every real dispatch). The unit
test `test/dispatch_render_test.mjs` covers the same three shapes
plus two more (adapter failure, raw appendix for unparsed `[tts:…]`
lines).

## Deferred

- **`[tts:…]` and `[exec:…]` adapter lines** — the digest parser
  (`dispatch_digest.mjs`) currently only recognises `claude_tool:`
  and `mcp:` channels. The runtime emits `[tts:elevenlabs]` and
  `[exec:…]` adapter lines that fall through to the raw appendix.
  When those channels join the parser the renderer will surface
  them as 📞 adapter rows in the timeline automatically.
- **State delta** — the renderer shows post-state only. A real
  `before → after` diff would require shelling `storehouse state`
  pre-dispatch (≈50–100 ms extra), or wiring the runtime to ship a
  prior snapshot back. v1 defers this ; the post-state list already
  reads cleanly for most dispatches.
