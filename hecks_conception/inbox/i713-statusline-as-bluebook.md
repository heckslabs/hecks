# i713 — statusline → bluebook (leaked domain : rendering body state lives in the binary)

The statusline (`rust/src/run_statusline/`) renders the body's state — heart phase,
inbox channels, sleep/wake — but it lives in the compiled Rust binary. Dropping ONE
segment tonight (the dead speech-latency stats) required hand-editing Rust + a ~13s
recompile + reinstall + a whole sidequest. That friction IS the leaked-domain smell:
rendering body state is a DOMAIN concept (a query over Heart / Inbox channels /
Consciousness state), trapped in the ribosome.

The ribosome — parse, dispatch, execute — legitimately stays compiled. But the
statusline is BODY, not ribosome. It should be a bluebook: a `Statusline` aggregate
or a render query that reads the body's current state and composes the line. Then
changing it = editing a spec — no recompile, no agent, no rebuild.

Same family as the `main.rs` leaked-domain candidates (boot orchestration, census,
daemon lifecycle, circadian segments, the sleep ritual). And an early, low-risk
target for the **desugar-then-specialize** arc: reduce the imperative surface to a
declarative query, then let the specializer project the Rust statusline FROM it.

## Shape
- A `Statusline.render` query (or a small Statusline domain) reading
  Heart / inbox-channel / Consciousness state → the rendered string.
- The Rust `storehouse statusline` command becomes a thin caller of that query
  (eventually specializer-generated). The Claude Code `statusLine` hook is
  unchanged ; only the WHAT moves from binary to bluebook.
