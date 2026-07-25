//! adapter_wiring — hexagon adapter LOOKUPS : adapter_handler (declared
//! adapter name -> standalone handler program + family), family_fields (the
//! config fields a family declares), adapter_world_config (the per-deployment
//! values the .world carries for a binding).
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/adapter_wiring.rs — kernel-floor
//!  hexagon lookup surface, relocated verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    /// Resolve a hexagon adapter (by its declared name, e.g. "Stripe") to its
    /// standalone handler program path and family, walking the loaded
    /// hecksagons' adapter declarations. The standalone adapter HOST
    /// (`storehouse host`) uses this to learn which program to exec for a
    /// delivery whose `adapter` field names this adapter. Returns the FIRST
    /// match (adapter names are unique across a conception). `handler` is
    /// empty for in-process adapters (heki/memory) — those never shell out.
    pub fn adapter_handler(&self, adapter_name: &str) -> Option<(String, String)> {
        for hex in &self.hecksagons {
            for a in &hex.adapters {
                if a.name == adapter_name {
                    return Some((a.handler.clone(), a.family.clone()));
                }
            }
        }
        None
    }

    /// The config FIELDS a family declares — `(name, source)` pairs, source
    /// being `direct` | `env` | `secret` (empty defaults to direct). The
    /// standalone host (`run_host::config::map_config`) consults these to map a
    /// `.world` block onto the handler child's env per the field-source
    /// convention. Walks the loaded hecksagons' families (sibling of
    /// `adapter_handler`) ; returns empty when the family isn't found.
    pub fn family_fields(&self, family: &str) -> Vec<(String, String)> {
        for hex in &self.hecksagons {
            for f in &hex.families {
                if f.name == family {
                    return f
                        .fields
                        .iter()
                        .map(|fld| (fld.name.clone(), fld.source.clone()))
                        .collect();
                }
            }
        }
        Vec::new()
    }

    /// The per-adapter `.world` config (key→value pairs) the host folds into
    /// the handler child's environment, AFTER `run_host::config::map_config`
    /// applies the family field-source convention. Empty when no `.world` binds
    /// this adapter (the demo case — the handler then takes its built-in
    /// default path).
    pub fn adapter_world_config(&self, adapter_name: &str) -> Vec<(String, String)> {
        // The pizzas-form `Domain::Agg.verb("Adapter") do … end` lands in world
        // CONFIGS keyed by the LOWERCASED adapter name (config_for : "Stripe" ->
        // "stripe", "ElevenLabs" -> "elevenlabs"). Fall back to the older
        // `adapter "Name" do …` adapter_bindings form (exact name).
        let lname = adapter_name.to_lowercase();
        if let Some(c) = self.world_configs.iter().find(|c| c.name == lname) {
            return c.values.clone();
        }
        self.world_adapter_bindings
            .iter()
            .find(|b| b.name == adapter_name)
            .map(|b| b.values.clone())
            .unwrap_or_default()
    }
}
