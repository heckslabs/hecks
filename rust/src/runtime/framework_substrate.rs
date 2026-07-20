//! Framework substrate — the kernel's own aggregates, and how it reaches them.
//!
//! [antibody-exempt: rust/src/runtime/framework_substrate.rs — kernel-floor
//!  runtime, extracted verbatim from runtime/mod.rs (which carries the same
//!  marker). The collaborator that holds the runtime's OWN aggregates cannot
//!  itself be a bluebook : it is the mechanism by which bluebook substrate is
//!  reached at all.]
//!
//! The runtime must write aggregates the USER's domain does not own : the event
//! Log (`EventSourcing::Event`), the veto audit (`Governance::Violation`) and
//! the event-out outbox (`OutboundEvent`). It used to ask "is that aggregate in
//! MY domain?" and silently do nothing when it wasn't — a minimal boot wrote no
//! Log and lost authorization audit rows — while a graft spliced the outbox into
//! any domain with an effect port to paper over the third.
//!
//! The answer is a COLLABORATOR : a second Runtime booted on crate-owned
//! substrate that the kernel dispatches into. This module owns it — the embedded
//! bluebooks, the merged framework domain, the declared store location, the lazy
//! accessor, the inspection surface, and the DOOR-side lookup an out-of-process
//! caller needs.
//!
//! `CascadeRun` deliberately does NOT live here : its guard selects between two
//! WORKING paths (persistent outbox vs the in-memory pump), not between working
//! and losing data. See `inbox/CARD-framework-substrate-service.md`.
//!
//! Inherent `impl Runtime` methods in a child module, reaching Runtime's private
//! fields through child-module privacy and the `super::*` glob — the same shape
//! `query.rs` and `reaction.rs` use.

use super::*;

impl Runtime {
    /// The embedded framework outbox bluebook — the OutboundEvent event-out
    /// port, compiled in as runtime standard-library substrate so any booted
    /// domain with an effect binding gets it without copying. This is ENGINE
    /// stdlib (the messaging-port analog of CascadeRun), so the canonical copy
    /// is CRATE-OWNED (`rust/resources/outbound_event.bluebook`) — storehouse
    /// carries its own outbox contract and no longer reaches into a sibling
    /// `hecks_conception/` to build (decouple Phase 1). The conception keeps a
    /// copy (referenced by event_sourcing.bluebook) ; a monorepo parity check
    /// guards them against drift. Loaded into the framework collaborator, never
    /// merged into a user's domain.
    const OUTBOX_SUBSTRATE: &'static str = include_str!(
        "../../resources/outbound_event.bluebook"
    );

    /// The embedded EventSourcing chapter — the Event Log the kernel appends
    /// to. Crate-owned for the same reason the outbox is : storehouse must be
    /// able to event-source a domain without a sibling `hecks_conception/`.
    const EVENT_SOURCING_SUBSTRATE: &'static str = include_str!(
        "../../resources/event_sourcing.bluebook"
    );

    /// The embedded Governance chapter — the veto-audit sink every denied
    /// dispatch records to. Crate-owned for the same reason as the others : an
    /// authorization denial must be auditable on ANY runtime, not only one that
    /// happened to merge the Governance conception.
    const GOVERNANCE_SUBSTRATE: &'static str = include_str!(
        "../../resources/governance.bluebook"
    );

    /// Every framework substrate the collaborator carries, merged into one
    /// domain. Aggregates keep their own `context`, so FQN dispatch
    /// (`Governance::Violation.Record`, `EventSourcing::Event.Append`) resolves
    /// against the merge exactly as it would against a corpus.
    ///
    /// ONE collaborator, not one per substrate (CARD decision 1) : four boots
    /// would mean four stores and four times the wiring for a single mechanism.
    fn framework_domain() -> Domain {
        let mut domain = crate::parser::parse(Self::EVENT_SOURCING_SUBSTRATE);
        for source in [Self::GOVERNANCE_SUBSTRATE, Self::OUTBOX_SUBSTRATE] {
            let extra = crate::parser::parse(source);
            for agg in extra.aggregates {
                if !domain
                    .aggregates
                    .iter()
                    .any(|e| e.name == agg.name && e.context == agg.context)
                {
                    domain.aggregates.push(agg);
                }
            }
            domain.policies.extend(extra.policies);
        }
        domain
    }

    /// Every delivery currently in the framework outbox.
    ///
    /// The outbox is framework substrate and lives in the collaborator, so a
    /// caller inspecting it (a test, an operator tool) cannot reach it through
    /// its own domain any more — `rt.all("OutboundEvent")` returns nothing,
    /// correctly, because the user's domain never carried it. Empty when no
    /// delivery has ever been recorded (the collaborator has not booted).
    pub fn outbound_deliveries(&self) -> Vec<&AggregateState> {
        self.framework
            .as_ref()
            .map(|fw| fw.all("OutboundEvent"))
            .unwrap_or_default()
    }

    /// One delivery from the framework outbox, by delivery_id. The `find`
    /// sibling of `outbound_deliveries` — same reason it exists.
    pub fn outbound_delivery(&self, delivery_id: &str) -> Option<&AggregateState> {
        self.framework
            .as_ref()
            .and_then(|fw| fw.find("OutboundEvent", delivery_id))
    }

    /// Resolve a query against the framework collaborator (the outbox's
    /// `Pending` / `AllPending`, the Log, the veto audit). Returns an empty
    /// result shape when the collaborator has not booted.
    pub fn framework_query(
        &self,
        query_name: &str,
        attrs: &std::collections::HashMap<String, String>,
    ) -> serde_json::Value {
        match self.framework.as_ref() {
            Some(fw) => fw.resolve_query(query_name, attrs),
            None => serde_json::json!({ "state": [] }),
        }
    }

    /// The framework collaborator, booted on first use.
    ///
    /// This is the step-zero proof for CARD-framework-substrate-service : the
    /// kernel gets somewhere to dispatch framework commands that is NOT the
    /// user's domain. Booted lazily because most runtimes never append an
    /// Event, and paying a 400-line parse at every boot would tax all 124 test
    /// binaries for a path they don't take.
    ///
    /// It inherits `data_dir` so the Log lands under the same store root the
    /// parent writes to. (CARD decision 4 says the durable home is the
    /// FRAMEWORK REALM ; inheriting the parent's dir is the step-zero shape and
    /// is what keeps temp-dir tests isolated. Moving it to the framework realm
    /// is a follow-up, not a borrow-shape question.)
    ///
    /// The collaborator's own `framework` stays `None` — it never needs one,
    /// and that is what bounds the recursion.
    pub fn framework_mut(&mut self) -> &mut Runtime {
        if self.framework.is_none() {
            let dir = self.framework_store_dir();
            let rt = Runtime::boot_with_data_dir(Self::framework_domain(), dir);
            self.framework = Some(Box::new(rt));
        }
        self.framework.as_mut().expect("just booted")
    }

    /// The crate-owned world declaring WHERE the framework collaborator's stores
    /// live. Compiled in for the same reason the substrate bluebooks are :
    /// storehouse must build standalone with no sibling `hecks_conception`.
    #[cfg(not(target_arch = "wasm32"))]
    const FRAMEWORK_WORLD: &'static str = include_str!("../../resources/framework.world");

    /// Resolve the framework store location from its DECLARATION.
    ///
    /// The collaborator used to clone `self.data_dir` outright — the right
    /// location for the wrong reason, an accident nobody had declared. Now
    /// `framework.world` states it : `dir :default` means "the same folder as
    /// the host application's persistence", which is that same inherited
    /// `data_dir`. Behaviour is unchanged BY DESIGN — this converts an
    /// inheritance into a contract, so the location can be read rather than
    /// inferred, and a deployment can override it by naming a literal dir.
    ///
    /// Temp-dir isolation is preserved by construction : `:default` resolves to
    /// whatever the host is using, so a `/tmp` conception keeps its own store
    /// exactly as before.
    #[cfg(not(target_arch = "wasm32"))]
    fn framework_store_dir(&self) -> Option<String> {
        let world = crate::world::parser::parse(Self::FRAMEWORK_WORLD);
        match world.config_for("heki").and_then(|c| c.get("dir")) {
            // The declared default : co-locate with the host's persistence.
            Some("default") | None => self.data_dir.clone(),
            // An explicit location wins over the host's.
            Some(literal) => Some(crate::heki::expand_tilde(literal)),
        }
    }

    /// wasm has no world parser (`crate::world::parser` is cfg'd out) and no
    /// filesystem to point a literal dir at, so the declaration cannot be read
    /// there. That costs nothing : `dir :default` MEANS "inherit the host's
    /// store", which is exactly what this returns. A wasm worker therefore
    /// behaves identically to a host running the shipped declaration — it just
    /// cannot honour an overridden one, which it could not reach anyway.
    #[cfg(target_arch = "wasm32")]
    fn framework_store_dir(&self) -> Option<String> {
        self.data_dir.clone()
    }

    /// Can the framework collaborator resolve `<aggregate>.<tail>` — as either a
    /// query or a command on one of the substrate aggregates it owns?
    ///
    /// This is the DOOR-side half of the collaborator. An out-of-process door
    /// (the CLI, the adapter host) resolves a verb against the SERVED domain ;
    /// framework aggregates are deliberately not in that domain any more, so
    /// without this the verb falls through and dies as an unknown command. That
    /// is exactly how `dream_content_smoke` broke : every IN-process caller was
    /// rerouted to the collaborator and no out-of-process one was, so the whole
    /// unit suite stayed green while a cross-process read failed.
    ///
    /// Consulted ONLY AFTER the served domain fails to resolve, so the common
    /// path never pays for booting the collaborator. Derived from the substrate
    /// domain itself — never a hardcoded name list, which would drift the moment
    /// a substrate is added or renamed.
    pub fn framework_resolves(&mut self, aggregate: &str, tail: &str) -> bool {
        self.framework_mut()
            .domain
            .aggregates
            .iter()
            .filter(|a| a.name == aggregate)
            .any(|a| {
                a.queries.iter().any(|q| {
                    crate::util::snake_case(&q.name) == tail || q.name == tail
                }) || a.commands.iter().any(|c| c.name == tail)
            })
    }
}
