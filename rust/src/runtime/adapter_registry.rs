//! AdapterRegistry — runtime table of adapters declared in the hecksagon
//!
//! The bluebook IR says what commands exist and which events they emit.
//! The hecksagon IR says which adapters those events talk to. This
//! registry is the glue. It holds the parsed Hecksagon, exposes helpers
//! to look up adapters by kind/name, and drives the event fan-out when
//! a policy or command fires.
//!
//!   let reg = AdapterRegistry::from_hecksagon(hex);
//!   reg.shell("git_resolve_ref") -> Option<&ShellAdapter>
//!   reg.io("stdout")             -> Option<&IoAdapter>
//!   reg.subscribers_for("SessionStarted") -> Vec<&IoAdapter>
//!
//! The registry does not execute anything by itself — dispatcher modules
//! (ShellDispatcher, stdout/stdin/etc.) read its entries and perform the
//! I/O. Event routing here is intentionally simple: any IoAdapter whose
//! `on_events` list contains the event name is a subscriber.

use crate::hecksagon_ir::{Hecksagon, IoAdapter, ShellAdapter, Gate};

pub struct AdapterRegistry {
    pub hecksagon: Hecksagon,
}

impl AdapterRegistry {
    pub fn from_hecksagon(hecksagon: Hecksagon) -> Self {
        AdapterRegistry { hecksagon }
    }

    pub fn empty(name: &str) -> Self {
        AdapterRegistry {
            hecksagon: Hecksagon { name: name.into(), ..Hecksagon::default() },
        }
    }

    pub fn shell(&self, name: &str) -> Option<&ShellAdapter> {
        self.hecksagon.shell_adapter(name)
    }

    pub fn io(&self, kind: &str) -> Option<&IoAdapter> {
        self.hecksagon.io_adapter(kind)
    }

    pub fn gate_for(&self, aggregate: &str, role: &str) -> Option<&Gate> {
        self.hecksagon.gate_for(aggregate, role)
    }

    pub fn persistence(&self) -> Option<&str> {
        self.hecksagon.persistence.as_deref()
    }

    pub fn subscriptions(&self) -> &[String] {
        &self.hecksagon.subscriptions
    }

    /// Every IoAdapter whose `on_events` includes `event_name`. The
    /// runtime's policy engine emits events; adapters bound via
    /// `on :Event do … end` blocks fire side effects from that hook.
    pub fn subscribers_for(&self, event_name: &str) -> Vec<&IoAdapter> {
        self.hecksagon.io_adapters.iter()
            .filter(|a| a.on_events.iter().any(|e| e == event_name))
            .collect()
    }

    /// Convenience: list every declared shell adapter name.
    pub fn shell_names(&self) -> Vec<&str> {
        self.hecksagon.shell_adapters.iter().map(|a| a.name.as_str()).collect()
    }
}
