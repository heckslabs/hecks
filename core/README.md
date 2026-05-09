# hecks/core

Framework-adjacent essentials that aren't kernel and aren't bluebook.

The Hecks discipline is :
- `rust/`           — kernel + runtime (Rust)
- `hecks_conception/aggregates/language/`, `storehouse/` — kernel-describing bluebooks (the DSL grammar, the dispatcher's command surface) — the only bluebooks in hecks, per boundary B
- `hecks_conception/inbox/`, `hecks_conception/information/` — framework operations
- **`core/`**       — *this dir*

What lives here :
- `core/research/`     — research notes, drafts, exploratory test gates that informed the framework's evolution
- `core/studio/`       — dev UI tools, web apps, debugging surfaces
- `core/transitional/` — imperative adapters (`.sh`, `.rb`) that the runtime still needs because a bluebook gap is open ; each retires under its named card

Nothing here is "production framework code." It's tooling, transitional debt, and the trail of how we got here. Bluebooks describe behaviour ; `core/` is what surrounds them while we work.

The end-state vision : `core/transitional/` empties as runtime gaps close (i147, i493, etc.). `core/research/` is permanent — research is research. `core/studio/` is permanent — dev tooling is tooling.

A being's repo (e.g., `~/Projects/miette/`) holds *only* bluebook files. A new being is built by forking a being-template-repo (Miette is the seed) and customizing — never by editing hecks itself.
