//! A script's structural footprint, and the memo of footprints Postgres has already agreed on.
//!
//! The footprint keeps what decides how a store behaves and drops what does not: which verbs ran,
//! how the ids repeat (renamed by first appearance, so ids 2,2,0 and 1,1,3 match), whether each step
//! was accepted, and a class for each value (sign and magnitude of a number; length, non-ASCII,
//! quotes and control characters of a text). Two scripts with one footprint exercise the same store
//! paths with differently spelled data.
//!
//! That is a bet, and the memo hedges it: a footprint is re-verified on its 1st, 2nd, 4th, 8th...
//! repeat, so a value-dependent divergence inside one class still surfaces, at a cost that grows
//! with the logarithm of the repeats instead of with their number.

use crate::ops::{Cents, Id, Junk, Kind, Op, Script, Word};
use ahash::RandomState;
use dashmap::DashMap;
use std::collections::HashMap;
use std::hash::{BuildHasher, Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};

/// Entries kept before the memo is emptied, which bounds its memory over a long campaign.
const CAPACITY: usize = 1 << 20;

/// A script's footprint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Footprint(pub u64);

/// The hasher, with fixed keys so a footprint means the same thing on every run and every shard.
fn state() -> RandomState {
    RandomState::with_seeds(0x9E37_79B9, 0x7F4A_7C15, 0xBF58_476D, 0x1CE4_E5B9)
}

/// Renames ids by first appearance.
#[derive(Default)]
struct Renamer(HashMap<u8, u8>);

impl Renamer {
    fn name(&mut self, id: Id) -> u8 {
        let next = u8::try_from(self.0.len()).unwrap_or(u8::MAX);
        *self.0.entry(id.0).or_insert(next)
    }
}

fn class_of_cents(cents: Cents) -> (bool, u32) {
    (
        cents.0 < 0,
        cents
            .0
            .unsigned_abs()
            .checked_ilog2()
            .map_or(0, |bits| bits + 1),
    )
}

fn class_of_word(word: &Word) -> (u8, bool, bool, bool) {
    class_of_text(&word.0)
}

fn class_of_text(text: &str) -> (u8, bool, bool, bool) {
    let length = match text.chars().count() {
        0 => 0,
        1..=3 => 1,
        4..=15 => 2,
        _ => 3,
    };
    (
        length,
        !text.is_ascii(),
        text.contains(['"', '\\', '\'']),
        text.chars().any(char::is_control),
    )
}

fn hash_op<H: Hasher>(op: &Op, names: &mut Renamer, h: &mut H) {
    std::mem::discriminant(op).hash(h);
    match op {
        Op::Register {
            customer,
            given,
            family,
            email,
        } => {
            names.name(*customer).hash(h);
            [given, family]
                .iter()
                .for_each(|w| class_of_word(w).hash(h));
            class_of_text(&email.0).hash(h);
        }
        Op::Open {
            number,
            kind,
            limit,
            customer,
        } => {
            names.name(*number).hash(h);
            match kind {
                Kind::Current => 0_u8.hash(h),
                Kind::Savings => 1_u8.hash(h),
                Kind::Reserve => 2_u8.hash(h),
                Kind::Other(w) => (3_u8, class_of_word(w)).hash(h),
            }
            class_of_cents(*limit).hash(h);
            names.name(*customer).hash(h);
        }
        Op::Credit {
            number,
            amount,
            narrative,
        } => {
            names.name(*number).hash(h);
            class_of_cents(*amount).hash(h);
            class_of_word(narrative).hash(h);
        }
        Op::Freeze { number } => names.name(*number).hash(h),
        Op::Transfer {
            reference,
            amount,
            narrative,
            source,
            destination,
        } => {
            names.name(*reference).hash(h);
            class_of_cents(*amount).hash(h);
            class_of_word(narrative).hash(h);
            (names.name(*source), names.name(*destination)).hash(h);
        }
        Op::Malformed { verb, junk } => {
            verb.hash(h);
            match junk {
                Junk::Null => 0_u8.hash(h),
                Junk::Flag(b) => (1_u8, b).hash(h),
                Junk::Number(n) => (2_u8, class_of_cents(Cents(*n))).hash(h),
                Junk::Text(w) => (3_u8, class_of_word(w)).hash(h),
                Junk::List => 4_u8.hash(h),
            }
        }
    }
}

/// The footprint of `script` once it ran, `accepted` holding the in-memory store's answer to each
/// step: whether a step was refused is part of the path it took.
#[must_use]
pub fn of(script: &Script, accepted: &[bool]) -> Footprint {
    let mut hasher = state().build_hasher();
    let mut names = Renamer::default();
    script.ops.iter().zip(accepted).for_each(|(op, ok)| {
        hash_op(op, &mut names, &mut hasher);
        ok.hash(&mut hasher);
    });
    Footprint(hasher.finish())
}

/// Footprints Postgres has agreed on, each with how many times it has been seen since.
#[derive(Default)]
pub struct Memo {
    seen: DashMap<Footprint, u64>,
    pub skipped: AtomicU64,
    pub verified: AtomicU64,
}

impl Memo {
    /// Whether Postgres must be asked about `print`: the first time, and on each power-of-two repeat.
    pub fn due(&self, print: Footprint) -> bool {
        let due = match self.seen.get_mut(&print) {
            None => true,
            Some(mut repeats) => {
                *repeats += 1;
                repeats.is_power_of_two()
            }
        };
        let counter = if due { &self.verified } else { &self.skipped };
        counter.fetch_add(1, Ordering::Relaxed);
        due
    }

    /// Records that Postgres agreed on `print`.
    pub fn agreed(&self, print: Footprint) {
        if self.seen.len() >= CAPACITY {
            self.seen.clear();
        }
        self.seen.entry(print).or_insert(0);
    }
}
