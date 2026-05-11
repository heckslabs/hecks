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
//! Freshness (i517 dream-and-bug correspondence) :
//! `last_seen_mtime` tracks the heki file's mtime as of our last
//! load or save. `refresh_from_heki` stat()s the file and reloads
//! when disk has advanced — closing the cross-process staleness gap
//! a long-running daemon hits when a sibling process writes to the
//! same store. The bluebook contract for this lives in
//! runtime/storage/storage.bluebook (last_seen_mtime attribute,
//! RefreshIfStale command, RefreshOnPulse policy).
//!
//! Usage:
//!   let repo = Repository::new("Heartbeat", data_dir, Some("name".into()));
//!
//! [antibody-exempt: runtime aggregate store ;
//!  (a) identified_by dispatch drives natural-key vs counter-mint (i80) ;
//!  (b) cross-process freshness — load_persisted / save / refresh_from_heki
//!      track and re-read on mtime advance, honoring the storage.bluebook
//!      RefreshIfStale + RefreshOnPulse contract (i517 root cause).]

use super::AggregateState;
use super::Value;
use crate::heki;
use std::collections::HashMap;
use std::time::SystemTime;

