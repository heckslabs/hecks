//! Terraform HCL projector — walks Hecksagon IR + World IR, emits HCL.
//!
//! Implements the contract declared in
//! hecks_conception/aggregates/framework/projection/terraform.bluebook
//! (TerraformProjector aggregate, ProjectHecksagon + ProjectAdapter
//! commands). The projector :
//!
//!   1. Reads the hecksagon's adapter list (kind + name + options).
//!   2. Looks up each kind in `mappings::resource_type_for` ; unknown
//!      kinds (no cloud-resource analog) are skipped.
//!   3. Merges the adapter's inline options with the matching world
//!      block keyed by the adapter's name. World wins on key collision.
//!   4. Emits one `resource "<type>" "<name>" { ... }` block per
//!      resolved adapter, plus a provider block driven by the world's
//!      `aws do … end` block when present.
//!
//! The output is a single HCL string. The CLI wraps this in a file
//! write ; tests diff it against golden fixtures.

use crate::hecksagon_ir::Hecksagon;
use crate::world_ir::World;

pub mod hcl;
pub mod mappings;

/// Result of projecting one hecksagon : the emitted HCL string + the
/// count of adapters that successfully projected to a resource block.
/// Adapters with no mapping (e.g. :memory, :tts) are not counted.
#[derive(Debug, Clone, Default)]
pub struct ProjectionResult {
    pub hcl: String,
    pub adapter_count: usize,
}

/// Project a parsed hecksagon (+ optional world) to Terraform HCL.
///
/// When `world` is `None`, only the adapter's inline options drive
/// the resource properties — useful for round-trip golden testing
/// where the world's environment-specific values are absent.
pub fn project_hecksagon(hecksagon: &Hecksagon, world: Option<&World>) -> ProjectionResult {
    let mut out = String::new();
    let mut count = 0usize;

    // Header — every hecksagon's projection carries its name as a
    // top-of-file comment so the source is one click away.
    out.push_str(&format!(
        "# Generated from hecksagon \"{}\" — storehouse project terraform\n\n",
        hecksagon.name
    ));

    // Provider block when the world declares one. AWS only in Phase 1 ;
    // sibling provider blocks (gcp / azure) join in Phase 2.
    if let Some(w) = world {
        if let Some(provider_hcl) = hcl::provider_block_for(w) {
            out.push_str(&provider_hcl);
            out.push('\n');
        }
    }

    for adapter in &hecksagon.io_adapters {
        let resource_type = match mappings::resource_type_for(&adapter.kind) {
            Some(rt) => rt,
            None => continue,
        };
        // Adapter must have a name : Phase 1 skips nameless adapters
        // (which would mean `adapter :sqs` with no `name:`). The name
        // is the Terraform resource's logical id ; without it there is
        // nothing to write.
        let name = match name_from_options(&adapter.options) {
            Some(n) => n,
            None => continue,
        };
        let inline_props: Vec<(String, String)> = adapter
            .options
            .iter()
            .filter(|(k, _)| k != "name")
            .cloned()
            .collect();
        let world_props = world
            .and_then(|w| w.config_for(&name))
            .map(|cfg| cfg.values.clone())
            .unwrap_or_default();
        let merged = merge_props(&inline_props, &world_props);

        let block = hcl::resource_block(resource_type, &name, &merged);
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push('\n');
        }
        out.push_str(&block);
        out.push('\n');
        count += 1;
    }

    ProjectionResult { hcl: out, adapter_count: count }
}

/// Project a single adapter to its resource block. Used by the
/// ProjectAdapter command path and by programmatic callers that have
/// already resolved the world property bag.
pub fn project_adapter(
    kind: &str,
    name: &str,
    inline_props: &[(String, String)],
    world_props: &[(String, String)],
) -> Option<String> {
    let resource_type = mappings::resource_type_for(kind)?;
    let filtered: Vec<(String, String)> = inline_props
        .iter()
        .filter(|(k, _)| k != "name")
        .cloned()
        .collect();
    let merged = merge_props(&filtered, world_props);
    Some(hcl::resource_block(resource_type, name, &merged))
}

/// Merge adapter inline options with the world block. World wins on
/// key collision — that is the documented contract (world is the
/// deployment-time override). Order preserves inline first, then any
/// world-only keys (alphabetical inside each group is the responsibility
/// of the HCL writer).
fn merge_props(
    inline: &[(String, String)],
    world: &[(String, String)],
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::with_capacity(inline.len() + world.len());
    let world_keys: std::collections::HashSet<&str> =
        world.iter().map(|(k, _)| k.as_str()).collect();
    for (k, v) in inline {
        if !world_keys.contains(k.as_str()) {
            out.push((k.clone(), v.clone()));
        }
    }
    for (k, v) in world {
        out.push((k.clone(), v.clone()));
    }
    out
}

fn name_from_options(options: &[(String, String)]) -> Option<String> {
    options.iter().find(|(k, _)| k == "name").map(|(_, v)| {
        // The parser strips the leading colon from symbol form but
        // leaves quoted strings with their quotes ; normalize here.
        let raw = v.trim();
        if raw.starts_with('"') && raw.ends_with('"') && raw.len() >= 2 {
            raw[1..raw.len() - 1].to_string()
        } else {
            raw.trim_start_matches(':').to_string()
        }
    })
}
