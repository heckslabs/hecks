---
ref: i528-explorer-codegen
status: design
priority: high
value: 'Teach the wasm_worker specializer to consume :web adapter declarations from any loaded hecksagon, so the Hecks Explorer (Living Diagram + walking skeleton) ships as a Pages+Worker deploy alongside every app — not a static snapshot.'
posted_at: 2026-05-11
source: internal (Alan-call debrief — demo missed because explorer was localhost-only)
category: codegen
---

# i528-explorer-codegen — wasm_worker walks `:web` adapters

## Why this card exists

After the Alan call, the team agreed the missed-demo asset was
the Living Diagram + walking skeleton — the visualization that
*shows* bluebook-first generation rather than narrating it. The
surface exists in `rust/src/server/html_diagram.rs` (i527) and
`rust/src/server/html_domain.rs` (the walking skeleton), declared
in `runtime/living_diagram/living_diagram.hecksagon` as five
`:web` adapter routes. It runs on the local dev server only.

Today's stop-gap : a static snapshot at
**https://hecks-explorer.pages.dev** — captured from
`storehouse serve ~/Projects/bin-buddy` and dropped on
Cloudflare Pages under `deployments/explorer/public/`. Read-only
(dispatch forms render but POSTs go nowhere), single-bluebook
(BinBuddy), frozen at snapshot time.

The durable answer : extend the `wasm_worker` specializer to
walk every loaded hecksagon's `:web` adapter declarations and
emit corresponding `Router::get/post_async` handlers. Then the
same `storehouse specialize wasm_worker --app <app>` command
that already emits `bin-buddy/worker/src/lib.rs` produces a
Worker that serves `/diagram`, `/diagram/:domain_name`,
`/diagram/:domain_name/graph.json`, `/domains`, `/domains/:name`,
and `POST /domains/:name/dispatch` alongside today's `/route`
+ `/health` + `/lexicon` + `/query`.

## What's known

**The `:web` adapter primitive is already in :**
- `runtime/living_diagram/living_diagram.bluebook` — domain
  (Diagram + CascadeTrace + FormSubmission, 19 commands, 9 policies).
- `runtime/living_diagram/living_diagram.hecksagon` — `:web`
  routes (`/diagram`, `/diagram/:domain_name`, `/diagram/:domain_name/graph.json`,
  `/diagram/_all/graph.json`, `/diagram/flows.json`).
- `rust/src/server/web_adapter.rs` — `WebRegistry::scan` walks
  hecksagons and indexes the routes ; dev server's `multi.rs`
  matches incoming HTTP and dispatches through the registry.

**The wasm_worker specializer emits :**
- `rust/src/specializer/wasm_worker.rs` — 361 lines. `emit_lib_rs`
  hardcodes the four bus routes (`/health`, `/lexicon`, `/query`,
  `/route`). No `:web` adapter consumption.

**The runtime IR + html renderers compile to WASM :**
- `storehouse` is `#[target.'cfg(target_arch = "wasm32")']`-aware
  for R2 (`heki_r2.rs`). `pub mod server` is already in the crate's
  public surface ; html_domain + html_diagram + WebRegistry +
  multi's routing logic are all target-agnostic Rust.
- The bin-buddy worker already has 27 bluebooks embedded —
  enough to build a Runtime in-Worker at boot.

## What the codegen extension needs

1. **Walk loaded hecksagons during codegen.** Pull every `:web`
   adapter declaration : `name`, `method` (defaults `GET`), `path`,
   `template_path`, `serializer`, `content_type`, `domain_name`
   binding (literal or `:domain_name` placeholder).

2. **Embed template files alongside bluebooks.** Today
   `embedded::EMBEDDED_BLUEBOOKS` is the codegen output ; add
   `embedded::EMBEDDED_TEMPLATES: &[(&str, &str)]` indexed by
   `template_path`. Workers load templates at boot the same way
   they load bluebooks.

3. **Emit one `Router` registration per `:web` route.** Each
   route's handler reads (path captures), looks up the
   serializer / template, calls into the storehouse runtime,
   returns the HTML / JSON.

4. **Wire dispatch.** `POST /domains/:name/dispatch` already
   exists in `multi.rs` ; emit a wasm-target handler that does
   the same thing — parses body, dispatches through the runtime,
   returns the event.

5. **1MB ceiling check.** CF Worker free tier caps WASM at 1MB
   bundle ; today's bin-buddy worker is ~280KB. Embedding all
   the framework hecksagons + templates plus the html_diagram /
   html_domain code paths may push close. Measure during build.

## Companion

- This card is the durable answer to the static snapshot
  shipped today at `deployments/explorer/`.
- It exercises i527's `:web` adapter primitive on
  Cloudflare for the first time.
- It unblocks Pages+Worker for every Hecks-generated app, not
  just bin-buddy — bookshelf + todo + any future deploy ships
  the Explorer surface for free once this is in.

## Status

Design. Static-snapshot demo deployed at
https://hecks-explorer.pages.dev as the interim share-link
(see `deployments/explorer/`). Codegen extension scheduled for
next focused work block.
