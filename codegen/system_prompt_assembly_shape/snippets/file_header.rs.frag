//! Phase 4 — GenerateSystemPrompt
//!
//! [antibody-exempt: rust/src/run_boot/system_prompt.rs —
//!  Rust implementation of the deferred Phase 4 in run_boot/. Assembles
//!  the system prompt from the per-being content fixtures
//!  `<being>/self/system_prompt/system_prompt_content.fixtures` (a
//!  `Hecks.fixtures "SystemPromptContent"` file whose
//!  `SystemPromptSection` rows each carry an `order` + a `markdown`
//!  body), ordered by `:order`, then substitutes the two remaining
//!  placeholders — `{{standards}}` (primary's standards.md) and
//!  `{{grammar}}` (the language/grammar bluebooks) — and writes the
//!  result to `<being>/self/system_prompt.md`. This is i145 Phase 2 :
//!  the bluebook content fixtures are the single source ; the former
//!  flat `<being>_prompt.md.template` is retired. Retires fully under
//!  i78 when this phase regenerates from a meta-shape.]
//!
//! Why fixtures instead of the flat template (i145 Phase 2) :
//!
//!   - Phase 1 lifted every section's body into
//!     `system_prompt_content.fixtures` as `SystemPromptSection` rows.
//!     The flat `<being>_prompt.md.template` was a parallel copy that
//!     DRIFTED : sections authored in the fixtures never reached the
//!     rendered prompt because the render read the template, not the
//!     fixtures. Reading the fixtures directly makes the bluebook
//!     content the single source of truth and that drift impossible.
//!   - Only two placeholders remain dynamic : `{{standards}}` and
//!     `{{grammar}}`. Every other section is pre-baked per being in
//!     that being's own fixtures file.
//!
//! Per-being fixtures :
//!
//!   <being>/self/system_prompt/system_prompt_content.fixtures
//!
//! Spring's fixtures don't exist yet — when the second being lands the
//! file appears alongside Miette's and the runner picks it up by
//! being-name lookup. Until then a Spring boot surfaces a warning + skip.
