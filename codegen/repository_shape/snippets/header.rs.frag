//! Repository — in-memory aggregate storage with heki persistence
//!
//! Stores AggregateState instances by id. On every save, upserts
//! to a .heki store so state is shared with Miette's organs.
//!
//! Id dispatch (id_for_command): driven entirely by `identified_by`
//! from the aggregate IR — no defaults, no singleton fallback.
//!
//! Callers must always supply the id explicitly:
//!   identified_by :name  → pass name=heartbeat in command attrs
//!   identified_by :ref   → pass ref=abc123 in command attrs
//!
//! Without identified_by, mints a u64 counter on creation.
//!
//! Usage:
//!   let repo = Repository::new("Heartbeat", data_dir, Some("name".into()));
//!
//! [antibody-exempt: runtime aggregate store; identified_by dispatch drives natural-key vs counter-mint (i80)]

use super::AggregateState;
use super::Value;
use crate::heki;
use std::collections::HashMap;

