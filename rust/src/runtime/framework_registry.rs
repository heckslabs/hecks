//! FrameworkRegistry — typed runtime registry for Phase-2 framework
//!
//! i557 names the Phase-2 framework runtime: at boot, walk
//! `framework/adapter_families/` + `framework/behavior_kinds/`, build
//! typed registries from the bluebook definitions, and route dispatch
//! through them. Today the parser already stamps `framework_kind` on
//! Hecksagon IR but the runtime ignores it — this module closes that
//! gap. Part 1 (this card) lands the registry surface + boot wiring +
//! kernel hook registration. Part 2 retires the hardcoded `:claude_tool`
//! shortcut from `Runtime::dispatch`.
//!
//! Contract:
//!   - `AdapterFamily` describes a category of adapter declared under
//!     `framework/adapter_families/<name>.hecksagon`. Fields, trigger
//!     attribute, response attribute, and the behavior it implements
//!     come from the hecksagon body ; `providers` lists concrete impls.
//!   - `BehaviorKind` describes a verb the kernel can run on behalf of
//!     a family (`framework/behavior_kinds/<name>.hecksagon`). It names
//!     the fields the behavior requires and which command attribute
//!     triggers it.
//!   - `KernelHook` is the native function the runtime calls when a
//!     family's behavior fires. The registry stores hooks by behavior
//!     name so a dispatch knows which closure to run. Today the only
//!     seeded hook is `invoke_claude_tool` ; sms / tts / web_tool /
//!     future behaviors slot in here without runtime edits.
//!   - `FrameworkRegistry` is the lookup table: family + behavior maps
//!     keyed by name plus the hook map. `build_from_dir` walks a root
//!     and populates the maps ; `lookup_family` resolves an IR
//!     adapter's `kind` to the family that owns it, and `lookup_hook`
//!     resolves a behavior name to its native handler.
//!
//! Parser gap (i557 follow-up) : the Hecksagon parser captures
//! `framework_kind = "adapter_family"` / `"behavior_kind"` but NOT the
//! inner declarations (`fields`, `behavior`, `requires_field`, etc.).
//! Per i557 option #2, this module re-parses the framework files at
//! boot via a small dedicated reader (`parse_adapter_family_file` /
//! `parse_behavior_kind_file`). The structurally honest path is
//! extending the IR ; that work is filed as a follow-up so this card
//! ships the registry surface without parser ripple.
//!
//! Usage:
//!   let reg = FrameworkRegistry::build_from_dir(framework_dir);
//!   if let Some(family) = reg.lookup_family("claude_tool") { ... }
//!   if let Some(hook)   = reg.lookup_hook("invoke_claude_tool") {
//!       let result = hook(&adapter_fields, &command_attrs);
//!   }
//!
//! [antibody-exempt: rust/src/runtime/framework_registry.rs —
//!  kernel-floor module per i557. The framework registry is what
//!  *enables* bluebook-driven dispatch ; it cannot itself be bluebook-
//!  described until the very mechanism it provides is live. Retire
//!  this marker when `framework/adapter_families/` +
//!  `framework/behavior_kinds/` generate this module via the meta-
//!  shape compiler (i557 follow-up).]

use std::collections::HashMap;
use std::path::Path;

use crate::runtime::claude_tool_dispatcher;
use crate::runtime::mcp_dispatcher;

/// A category of adapter declared under
/// `framework/adapter_families/<name>.hecksagon`.
///
/// Example: a `claude_tool` family has fields like `name`, `command`,
/// `tool`, `result_into`, with `command` as the trigger field,
/// `result_into` as the response field, and `invoke_claude_tool` as the
/// behavior. Providers list the concrete adapter names that implement
/// the family.
#[derive(Debug, Clone, Default)]
pub struct AdapterFamily {
    pub name: String,
    pub fields: Vec<String>,
    pub trigger_field: Option<String>,
    pub response_field: Option<String>,
    /// Primary behavior — most families have one ; multi-behavior
    /// families take the first declared one as primary, with the full
    /// list in `behaviors`.
    pub behavior: Option<String>,
    /// All declared behaviors. Single-behavior families have one entry
    /// ; multi-behavior families (e.g. a future `:web_tool` with
    /// perform_web_fetch + perform_web_search) carry several.
    pub behaviors: Vec<String>,
    pub providers: Vec<String>,
}

/// A verb the kernel can run on behalf of a family.
///
/// Declared under `framework/behavior_kinds/<name>.hecksagon`. Names
/// the fields required to invoke the behavior and which command
/// attribute triggers it at dispatch time.
#[derive(Debug, Clone, Default)]
pub struct BehaviorKind {
    pub name: String,
    pub required_fields: Vec<String>,
    pub trigger_attribute: Option<String>,
}

/// Result envelope returned by every kernel hook.
///
/// Generic enough to carry the existing `ClaudeToolResult` shape
/// (tool/ok/output/exit_code) and future families' results (e.g.
/// `:sms` sends, `:tts` audio renders, `:web_tool` HTTP responses).
/// The dispatcher folds these fields into the follow-on cascade attrs.
#[derive(Debug, Clone, Default)]
pub struct KernelResult {
    /// Family-specific identifier of what ran ("bash", "edit",
    /// "send_message", "render_text_to_audio", etc.). Maps to the
    /// adapter's :tool / :operation field per family convention.
    pub kind: String,
    /// True if the hook succeeded.
    pub ok: bool,
    /// stdout / response body / file contents / etc.
    pub output: String,
    /// Shell exit code (or HTTP status) when applicable ; 0 for non-
    /// shell hooks.
    pub exit_code: i32,
    /// Human-readable error when `ok == false`.
    pub error: Option<String>,
}

/// Native handler bound to a behavior name.
///
/// The runtime calls this when a family's behavior fires. The hook
/// receives the adapter's declared field values + the dispatched
/// command's attrs (both as String maps for kernel-floor simplicity)
/// and returns a structured `KernelResult` the dispatcher routes back
/// through the family's `response_field`.
///
/// Function pointer (not boxed closure) so the registry stays cheaply
/// Clone-friendly and the indirection is one jump.
pub type KernelHook =
    fn(adapter_fields: &HashMap<String, String>, command_attrs: &HashMap<String, String>) -> KernelResult;

/// Typed registry of framework families, behaviors, and their hooks.
///
/// One instance per running Runtime ; populated at boot by
/// `build_from_dir(framework_dir)` which walks the framework hecksagons
/// + seeds the known kernel hooks. The dispatcher consults
/// `lookup_family` when an IR adapter carries a `kind` matching a
/// registered family, then `lookup_hook` to find the native handler.
#[derive(Default, Clone)]
pub struct FrameworkRegistry {
    pub families: HashMap<String, AdapterFamily>,
    pub behaviors: HashMap<String, BehaviorKind>,
    pub hooks: HashMap<String, KernelHook>,
}

impl FrameworkRegistry {
    /// Empty registry — no families, no behaviors, no hooks.
    pub fn new() -> Self {
        FrameworkRegistry {
            families: HashMap::new(),
            behaviors: HashMap::new(),
            hooks: HashMap::new(),
        }
    }

    /// Walk `<framework_dir>/adapter_families/*.hecksagon` and
    /// `<framework_dir>/behavior_kinds/*.hecksagon`, populate the
    /// family + behavior maps, then seed known kernel hooks.
    ///
    /// Per i557 option #2, this uses a small dedicated reader rather
    /// than extending the main Hecksagon parser. Files that fail to
    /// read or parse are silently skipped — the registry stays usable
    /// even if one family's file is missing or malformed.
    pub fn build_from_dir(framework_dir: &Path) -> Self {
        let mut reg = Self::new();

        let families_dir = framework_dir.join("adapter_families");
        if let Ok(entries) = std::fs::read_dir(&families_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().map(|e| e == "hecksagon").unwrap_or(false) {
                    if let Ok(source) = std::fs::read_to_string(&path) {
                        if let Some(fam) = parse_adapter_family_file(&source) {
                            reg.families.insert(fam.name.clone(), fam);
                        }
                    }
                }
            }
        }

        let behaviors_dir = framework_dir.join("behavior_kinds");
        if let Ok(entries) = std::fs::read_dir(&behaviors_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().map(|e| e == "hecksagon").unwrap_or(false) {
                    if let Ok(source) = std::fs::read_to_string(&path) {
                        if let Some(bk) = parse_behavior_kind_file(&source) {
                            reg.behaviors.insert(bk.name.clone(), bk);
                        }
                    }
                }
            }
        }

        seed_kernel_hooks(&mut reg);
        reg
    }

    /// Insert a native handler bound to a behavior name.
    ///
    /// Behaviors are hecksagon-declared but their implementations are
    /// native code. This is the seam between the two — the dispatcher
    /// looks up the hook by behavior name when a family fires.
    pub fn register_hook(&mut self, behavior_name: &str, hook: KernelHook) {
        self.hooks.insert(behavior_name.to_string(), hook);
    }

    /// Resolve a behavior name to its native handler.
    pub fn lookup_hook(&self, behavior_name: &str) -> Option<KernelHook> {
        self.hooks.get(behavior_name).copied()
    }

    /// Resolve an IR adapter `kind` to the family that owns it.
    pub fn lookup_family(&self, family_name: &str) -> Option<&AdapterFamily> {
        self.families.get(family_name)
    }
}

/// Seed kernel hooks for the families this kernel knows natively.
///
/// Today : `invoke_claude_tool` (the i551/i556 claude_tool family)
/// and `invoke_mcp_tool` (the i593 mcp family). Future families
/// (web_tool, sms, tts, ...) register their hooks here as their
/// kernel-side dispatchers land. The signature is the same for
/// every hook — the family declares the surface, the kernel
/// supplies the execution.
///
/// i594 — `invoke_mcp_tool` joins the table alongside
/// `invoke_claude_tool`. The :mcp adapter family (declared at
/// `aggregates/framework/adapter_families/mcp.hecksagon`) carries
/// `behavior :invoke_mcp_tool` ; without the registration below the
/// family parses cleanly but never fires. Adding the line here is
/// the i594-temporary path while bluebook-driven hook registration
/// (the i594 acceptance, an `inventory`-style discovery) is still
/// in design. Same exemption pattern as the rest of this kernel-
/// floor file.
fn seed_kernel_hooks(registry: &mut FrameworkRegistry) {
    registry.register_hook(
        "invoke_claude_tool",
        claude_tool_dispatcher::dispatch_via_registry,
    );
    registry.register_hook(
        "invoke_mcp_tool",
        mcp_dispatcher::dispatch_via_registry,
    );
    // web_tool follow-up : when `web_tool_dispatcher` lands on main
    // (currently lives only on the i569 worktree branches), seed it
    // here by iterating `web_tool_dispatcher::WEB_TOOL_BEHAVIOR_NAMES`
    // and calling `register_hook(name, web_tool_dispatcher::lookup_hook(name).unwrap())`.
    // sms / tts seed similarly when their kernel hooks land.
}

// ── Dedicated readers for framework hecksagons ──────────────────────
//
// Per i557 the main Hecksagon parser captures `framework_kind` on the
// IR but skips the inner DSL of adapter_family / behavior_kind blocks.
// These helpers read what we need (the inner declarations) without
// touching the main parser. They handle the small shape these
// hecksagons actually use ; not a full Ruby parser, just enough to
// pull fields / trigger_field / response_field / behavior / providers
// for `Hecks.adapter_family`, and required_fields / trigger_attribute
// for `Hecks.behavior_kind`. Comments and blank lines are skipped.

fn parse_adapter_family_file(source: &str) -> Option<AdapterFamily> {
    let mut fam = AdapterFamily::default();
    let mut found_header = false;

    for raw_line in source.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if line.starts_with("Hecks.adapter_family") {
            if let Some(n) = extract_between_quotes(line) {
                fam.name = n;
                found_header = true;
            }
            continue;
        }

        // fields :a, :b, :c, ...
        if line.starts_with("fields ") || line.starts_with("fields\t") {
            let rest = &line["fields".len()..];
            collect_symbols(rest, &mut fam.fields);
            continue;
        }

        // trigger_field :command
        if let Some(rest) = strip_keyword(line, "trigger_field") {
            if let Some(s) = first_symbol(rest) {
                fam.trigger_field = Some(s);
            }
            continue;
        }

        // response_field :result_into
        if let Some(rest) = strip_keyword(line, "response_field") {
            if let Some(s) = first_symbol(rest) {
                fam.response_field = Some(s);
            }
            continue;
        }

        // behavior :invoke_claude_tool  (singular ; per claude_tool family)
        if let Some(rest) = strip_keyword(line, "behavior") {
            if let Some(s) = first_symbol(rest) {
                if fam.behavior.is_none() {
                    fam.behavior = Some(s.clone());
                }
                if !fam.behaviors.contains(&s) {
                    fam.behaviors.push(s);
                }
            }
            continue;
        }

        // behaviors :a, :b   (plural ; multi-behavior families)
        if let Some(rest) = strip_keyword(line, "behaviors") {
            let mut all = Vec::new();
            collect_symbols(rest, &mut all);
            for b in &all {
                if !fam.behaviors.contains(b) {
                    fam.behaviors.push(b.clone());
                }
            }
            if fam.behavior.is_none() {
                if let Some(first) = all.first() {
                    fam.behavior = Some(first.clone());
                }
            }
            continue;
        }

        // providers :twilio, :vonage
        if let Some(rest) = strip_keyword(line, "providers") {
            collect_symbols(rest, &mut fam.providers);
            continue;
        }
    }

    if found_header && !fam.name.is_empty() {
        Some(fam)
    } else {
        None
    }
}

fn parse_behavior_kind_file(source: &str) -> Option<BehaviorKind> {
    let mut bk = BehaviorKind::default();
    let mut found_header = false;

    for raw_line in source.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if line.starts_with("Hecks.behavior_kind") {
            if let Some(n) = extract_between_quotes(line) {
                bk.name = n;
                found_header = true;
            }
            continue;
        }

        // requires_field :tool   (one per line ; can repeat)
        if let Some(rest) = strip_keyword(line, "requires_field") {
            if let Some(s) = first_symbol(rest) {
                bk.required_fields.push(s);
            }
            continue;
        }

        // trigger_attribute :description
        if let Some(rest) = strip_keyword(line, "trigger_attribute") {
            if let Some(s) = first_symbol(rest) {
                bk.trigger_attribute = Some(s);
            }
            continue;
        }
    }

    if found_header && !bk.name.is_empty() {
        Some(bk)
    } else {
        None
    }
}

// ── tiny line-parsing helpers ───────────────────────────────────────

fn extract_between_quotes(line: &str) -> Option<String> {
    let first = line.find('"')?;
    let rest = &line[first + 1..];
    let second = rest.find('"')?;
    Some(rest[..second].to_string())
}

/// Strip the keyword if the line starts with it followed by whitespace
/// (so `behavior :foo` matches but `behaviors :foo` doesn't, and
/// `trigger_field :foo` matches but `trigger_field_something` doesn't).
fn strip_keyword<'a>(line: &'a str, keyword: &str) -> Option<&'a str> {
    if !line.starts_with(keyword) {
        return None;
    }
    let after = &line[keyword.len()..];
    let next_byte = after.as_bytes().first()?;
    if matches!(*next_byte, b' ' | b'\t') {
        Some(after.trim_start())
    } else {
        None
    }
}

/// First `:symbol` on the line (sans the leading colon). Comments after
/// the symbol are tolerated.
fn first_symbol(s: &str) -> Option<String> {
    let trimmed = s.trim_start();
    let bytes = trimmed.as_bytes();
    if bytes.first() != Some(&b':') {
        return None;
    }
    let mut i = 1;
    while i < bytes.len() {
        let c = bytes[i];
        if c.is_ascii_alphanumeric() || c == b'_' {
            i += 1;
        } else {
            break;
        }
    }
    if i == 1 {
        None
    } else {
        Some(trimmed[1..i].to_string())
    }
}

/// Collect every `:symbol` on the rest of a line into `out`. Used for
/// `fields :a, :b, :c` and `providers :x, :y`. Stops at a trailing
/// `# comment`.
fn collect_symbols(s: &str, out: &mut Vec<String>) {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // Stop at trailing comment.
        if bytes[i] == b'#' {
            break;
        }
        if bytes[i] == b':' {
            // Start of a symbol — skip the colon, collect ident.
            i += 1;
            let start = i;
            while i < bytes.len()
                && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_')
            {
                i += 1;
            }
            if i > start {
                if let Ok(name) = std::str::from_utf8(&bytes[start..i]) {
                    out.push(name.to_string());
                }
            }
        } else {
            i += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_registry_lookups_return_none() {
        let reg = FrameworkRegistry::new();
        assert!(reg.lookup_family("claude_tool").is_none());
        assert!(reg.lookup_hook("invoke_claude_tool").is_none());
        assert!(reg.families.is_empty());
        assert!(reg.behaviors.is_empty());
        assert!(reg.hooks.is_empty());
    }

    #[test]
    fn parse_adapter_family_extracts_fields_and_behavior() {
        let source = r#"
Hecks.adapter_family "claude_tool" do
  # comment
  fields :name, :command, :tool, :result_into
  trigger_field :command
  response_field :result_into
  behavior :invoke_claude_tool
end
"#;
        let fam = parse_adapter_family_file(source).expect("parsed family");
        assert_eq!(fam.name, "claude_tool");
        assert_eq!(fam.fields, vec!["name", "command", "tool", "result_into"]);
        assert_eq!(fam.trigger_field.as_deref(), Some("command"));
        assert_eq!(fam.response_field.as_deref(), Some("result_into"));
        assert_eq!(fam.behavior.as_deref(), Some("invoke_claude_tool"));
        assert_eq!(fam.behaviors, vec!["invoke_claude_tool"]);
    }

    #[test]
    fn parse_adapter_family_with_plural_behaviors_and_providers() {
        let source = r#"
Hecks.adapter_family "sms" do
  fields :name, :behavior, :trigger_on, :response_into
  trigger_field :trigger_on
  response_field :response_into
  behaviors :call_sms_api
  providers :twilio
end
"#;
        let fam = parse_adapter_family_file(source).expect("parsed family");
        assert_eq!(fam.name, "sms");
        assert_eq!(fam.behavior.as_deref(), Some("call_sms_api"));
        assert_eq!(fam.behaviors, vec!["call_sms_api"]);
        assert_eq!(fam.providers, vec!["twilio"]);
    }

    #[test]
    fn parse_behavior_kind_extracts_required_and_trigger() {
        let source = r#"
Hecks.behavior_kind "invoke_claude_tool" do
  requires_field :tool
  requires_field :result_into
  trigger_attribute :description
end
"#;
        let bk = parse_behavior_kind_file(source).expect("parsed behavior");
        assert_eq!(bk.name, "invoke_claude_tool");
        assert_eq!(bk.required_fields, vec!["tool", "result_into"]);
        assert_eq!(bk.trigger_attribute.as_deref(), Some("description"));
    }

    #[test]
    fn build_from_dir_handles_missing_directories_cleanly() {
        // Pointing at a non-existent dir should return an empty
        // registry, not panic. Kernel hooks are still seeded though.
        let reg = FrameworkRegistry::build_from_dir(Path::new(
            "/nonexistent/path/that/does/not/exist",
        ));
        assert!(reg.families.is_empty());
        assert!(reg.behaviors.is_empty());
        // Hooks are seeded regardless of disk state — they're native.
        assert!(reg.lookup_hook("invoke_claude_tool").is_some());
        // i594 — invoke_mcp_tool seeds alongside invoke_claude_tool so
        // the :mcp adapter family fires once a binding matches.
        assert!(reg.lookup_hook("invoke_mcp_tool").is_some());
    }

    /// End-to-end discovery test : walking the real framework dir
    /// populates the claude_tool family, the invoke_claude_tool
    /// behavior, AND registers the kernel hook.
    ///
    /// Per the i557 acceptance criteria : a unit test that proves
    /// `build_from_dir(framework_dir)` populates with at least the
    /// claude_tool family + invoke_claude_tool behavior + the
    /// registered hook.
    #[test]
    fn build_from_dir_walks_real_framework() {
        // Locate the framework dir by walking up from CARGO_MANIFEST_DIR.
        // The crate lives at <repo>/rust/, framework dir at
        // <repo>/hecks_conception/aggregates/framework/.
        let manifest = std::env::var("CARGO_MANIFEST_DIR")
            .expect("CARGO_MANIFEST_DIR set under cargo");
        let framework_dir = Path::new(&manifest)
            .parent()
            .expect("rust crate has parent (repo root)")
            .join("hecks_conception/aggregates/framework");

        if !framework_dir.is_dir() {
            // Some build environments (sandboxed CI, sparse checkouts)
            // may not have hecks_conception present. Don't fail the
            // build there — just skip the assertion.
            eprintln!(
                "skipping framework-discovery test ; {} not a directory",
                framework_dir.display()
            );
            return;
        }

        let reg = FrameworkRegistry::build_from_dir(&framework_dir);

        let claude_tool = reg
            .lookup_family("claude_tool")
            .expect("claude_tool family populated");
        assert_eq!(claude_tool.name, "claude_tool");
        assert_eq!(claude_tool.behavior.as_deref(), Some("invoke_claude_tool"));

        let invoke = reg
            .behaviors
            .get("invoke_claude_tool")
            .expect("invoke_claude_tool behavior populated");
        assert_eq!(invoke.name, "invoke_claude_tool");

        let hook = reg
            .lookup_hook("invoke_claude_tool")
            .expect("invoke_claude_tool hook registered");
        // Sanity : the hook is callable and returns a structured
        // result. Calling with no shell_command attr exercises the
        // error path of the underlying dispatcher.
        let result = hook(
            &{
                let mut m = HashMap::new();
                m.insert("tool".to_string(), "bash".to_string());
                m
            },
            &HashMap::new(),
        );
        assert_eq!(result.kind, "bash");
        assert!(!result.ok); // Missing shell_command → ok=false.
        assert!(result.error.is_some());
    }
}
