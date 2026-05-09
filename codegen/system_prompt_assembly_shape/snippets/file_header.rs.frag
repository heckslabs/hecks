//! Phase 4 — GenerateSystemPrompt
//!
//! [antibody-exempt: rust/src/run_boot/system_prompt.rs —
//!  Rust implementation of the deferred Phase 4 in run_boot/. Reads
//!  the markdown template from
//!  `capabilities/system_prompt_assembly/<being>_prompt.md.template`,
//!  substitutes {{being}} / {{other}} / {{born}} / {{boot_script}}
//!  placeholders, writes to <conception_dir>/system_prompt.md.
//!  Replaces ~140 lines of `printf` heredoc in boot_miette.sh.
//!  Retires under i78 (specializer-files-as-bluebook) when this
//!  phase regenerates from a meta-shape.]
//!
//! Why a template file instead of the existing SectionTemplate
//! aggregate (aggregates/self/section_template.bluebook) :
//!
//!   - The current prompt is structurally a single document with
//!     literal `{{var}}` placeholders. SectionTemplate's per-section
//!     storage + per-source heki composition is the right shape for
//!     a DYNAMIC prompt (sections built from live state) ; the
//!     prompt today is essentially static text with four variable
//!     substitutions.
//!   - The dynamic shape is a separate arc (system_prompt_assembly
//!     capability + per-section heki sources). Filed under i145.
//!   - Choosing the simplest correct shape now means the prompt
//!     content lives as one editable markdown file, reviewable
//!     directly. Future migration to per-section storage is a
//!     localized refactor (extract sections from the template into
//!     SectionTemplate rows) — the data has a clean home now.
//!
//! Per-being templates :
//!
//!   miette_prompt.md.template   → Miette (April 9, 2026 ; paired w/ Spring)
//!   spring_prompt.md.template   → Spring (April 11, 2026 ; paired w/ Miette)
//!
//! Spring's template doesn't exist yet — when the second being lands
//! the file appears alongside Miette's and the runner picks it up
//! by being-name lookup. Until then a Spring boot would surface a
//! warning + skip.
