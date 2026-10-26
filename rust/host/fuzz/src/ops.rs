//! A script of Banking commands that libFuzzer's bytes decode into, through `arbitrary`.
//!
//! The argument shapes are the ones the host's own conformance suite sends
//! (`src/store_conformance.rs`), so a refusal here is the domain's rule speaking, not a malformed
//! request. Ids come from a small pool, so a script reuses customers and accounts and reaches the
//! refusals that depend on an earlier step (a duplicate, a frozen account).

use arbitrary::{Arbitrary, Result, Unstructured};
use serde_json::{json, Value};

/// How many distinct ids a script draws from. Small on purpose: collisions are the interesting case.
pub const POOL: u8 = 4;

/// The most steps one script holds. Every dispatch replays through the compiled kernel, so a long
/// script costs more than a wide one.
pub const MAX_STEPS: usize = 12;

/// The longest text a script carries in one field.
const MAX_WORD: usize = 24;

/// One id from the pool.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Id(pub u8);

impl Arbitrary<'_> for Id {
    fn arbitrary(u: &mut Unstructured<'_>) -> Result<Self> {
        Ok(Self(u.int_in_range(0..=POOL - 1)?))
    }
}

/// Money in cents: mostly small and plausible, sometimes an edge a numeric column mishandles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cents(pub i64);

impl Arbitrary<'_> for Cents {
    fn arbitrary(u: &mut Unstructured<'_>) -> Result<Self> {
        const EDGES: [i64; 7] = [0, -1, 1, i64::MAX, i64::MIN, 9_007_199_254_740_993, 100_000];
        Ok(Self(if u.ratio(1, 8)? {
            *u.choose(&EDGES)?
        } else {
            u.int_in_range(0..=100_000)?
        }))
    }
}

/// Free text that passes the domain's "has a visible character" rule, so a step reaches the
/// domain's own rules instead of failing at the door (`Malformed` is where the door is tested).
///
/// A NUL is dropped because Postgres `jsonb` cannot hold U+0000 at all, which is a property of that
/// store and not a divergence worth a crash on every run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Word(pub String);

impl Arbitrary<'_> for Word {
    fn arbitrary(u: &mut Unstructured<'_>) -> Result<Self> {
        let text: String = u.arbitrary()?;
        let kept: String = text.chars().filter(|c| *c != '\0').take(MAX_WORD).collect();
        let visible = kept.chars().any(|c| !matches!(c, ' ' | '\t' | '\n' | '\r'));
        Ok(Self(if visible { kept } else { "w".to_string() }))
    }
}

/// The local part of an address; the domain part is fixed, so the address matches the rule
/// `^[^@ ]+@[^@ ]+\.[^@ ]+$` that `EmailAddress` holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Email(pub String);

impl Arbitrary<'_> for Email {
    fn arbitrary(u: &mut Unstructured<'_>) -> Result<Self> {
        let text: String = u.arbitrary()?;
        let local: String = text
            .chars()
            .filter(char::is_ascii_alphanumeric)
            .take(MAX_WORD)
            .collect();
        Ok(Self(if local.is_empty() {
            "a".to_string()
        } else {
            local
        }))
    }
}

/// The account kinds the domain admits, and any other word.
#[derive(Debug, Clone, PartialEq, Eq, Arbitrary)]
pub enum Kind {
    Current,
    Savings,
    Reserve,
    Other(Word),
}

impl Kind {
    fn name(&self) -> &str {
        match self {
            Self::Current => "current",
            Self::Savings => "savings",
            Self::Reserve => "reserve",
            Self::Other(word) => &word.0,
        }
    }
}

/// A value that is not the type its field wants.
#[derive(Debug, Clone, PartialEq, Arbitrary)]
pub enum Junk {
    Null,
    Flag(bool),
    Number(i64),
    Text(Word),
    List,
}

/// The verbs a script can address.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Arbitrary)]
pub enum Verb {
    Register,
    Open,
    Credit,
    Freeze,
    Transfer,
}

/// One command in a script.
#[derive(Debug, Clone, PartialEq, Arbitrary)]
pub enum Op {
    Register {
        customer: Id,
        given: Word,
        family: Word,
        email: Email,
    },
    Open {
        number: Id,
        kind: Kind,
        limit: Cents,
        customer: Id,
    },
    Credit {
        number: Id,
        amount: Cents,
        narrative: Word,
    },
    Freeze {
        number: Id,
    },
    Transfer {
        reference: Id,
        amount: Cents,
        narrative: Word,
        source: Id,
        destination: Id,
    },
    /// A well-formed command whose first field is replaced by a value of the wrong type.
    Malformed {
        verb: Verb,
        junk: Junk,
    },
}

fn customer(id: Id) -> String {
    format!("CUST-{:04}", u32::from(id.0) + 1)
}

fn account(id: Id) -> String {
    let prefix = if id.0 < POOL / 2 { "src" } else { "dst" };
    format!("{prefix}-{:04}", u32::from(id.0) + 1)
}

fn transfer(id: Id) -> String {
    format!("tr-{:04}", u32::from(id.0) + 1)
}

impl Verb {
    /// The qualified verb the host dispatches.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Register => "Banking::Customer.Register",
            Self::Open => "Banking::Account.Open",
            Self::Credit => "Banking::Account.Credit",
            Self::Freeze => "Banking::Account.FreezeAccount",
            Self::Transfer => "Banking::Transfer.Request",
        }
    }

    /// A well-formed command of this verb with the first pool id throughout.
    fn template(self) -> Op {
        let (id, word) = (Id(0), || Word("x".to_string()));
        match self {
            Self::Register => Op::Register {
                customer: id,
                given: word(),
                family: word(),
                email: Email("x".to_string()),
            },
            Self::Open => Op::Open {
                number: id,
                kind: Kind::Current,
                limit: Cents(50_000),
                customer: id,
            },
            Self::Credit => Op::Credit {
                number: id,
                amount: Cents(1),
                narrative: word(),
            },
            Self::Freeze => Op::Freeze { number: id },
            Self::Transfer => Op::Transfer {
                reference: id,
                amount: Cents(1),
                narrative: word(),
                source: id,
                destination: Id(1),
            },
        }
    }
}

impl Op {
    /// The verb and arguments the host dispatches for this step.
    #[must_use]
    pub fn render(&self) -> (&'static str, Value) {
        match self {
            Self::Register {
                customer: c,
                given,
                family,
                email,
            } => (
                Verb::Register.name(),
                json!({
                    "reference": { "value": customer(*c) },
                    "name": { "given": given.0, "family": family.0 },
                    "email": { "address": format!("{}@example.com", email.0) },
                }),
            ),
            Self::Open {
                number,
                kind,
                limit,
                customer: c,
            } => (
                Verb::Open.name(),
                json!({
                    "number": { "value": account(*number) },
                    "kind": { "name": kind.name() },
                    "daily_limit": { "cents": limit.0 },
                    "customer": customer(*c),
                }),
            ),
            Self::Credit {
                number,
                amount,
                narrative,
            } => (
                Verb::Credit.name(),
                json!({
                    "number": account(*number),
                    "amount": { "cents": amount.0 },
                    "narrative": { "text": narrative.0 },
                }),
            ),
            Self::Freeze { number } => (
                Verb::Freeze.name(),
                json!({ "number": { "value": account(*number) } }),
            ),
            Self::Transfer {
                reference,
                amount,
                narrative,
                source,
                destination,
            } => (
                Verb::Transfer.name(),
                json!({
                    "reference": { "value": transfer(*reference) },
                    "amount": { "cents": amount.0 },
                    "narrative": { "text": narrative.0 },
                    "source": account(*source),
                    "destination": account(*destination),
                }),
            ),
            Self::Malformed { verb, junk } => {
                let (name, mut args) = verb.template().render();
                if let Some(first) = args.as_object_mut().and_then(|o| o.values_mut().next()) {
                    *first = junk.value();
                }
                (name, args)
            }
        }
    }
}

impl Junk {
    fn value(&self) -> Value {
        match self {
            Self::Null => Value::Null,
            Self::Flag(b) => json!(b),
            Self::Number(n) => json!(n),
            Self::Text(w) => json!(w.0),
            Self::List => json!([]),
        }
    }
}

/// A non-empty run of commands, played in order against one fresh store.
#[derive(Debug, Clone, PartialEq)]
pub struct Script {
    pub ops: Vec<Op>,
}

impl Arbitrary<'_> for Script {
    /// Three in four scripts open with a registered customer and one open account, because nearly
    /// every other command refuses until they exist and a script of refusals reaches little.
    fn arbitrary(u: &mut Unstructured<'_>) -> Result<Self> {
        let mut ops = Vec::new();
        if u.ratio(3, 4)? {
            ops.push(Op::Register {
                customer: Id(0),
                given: u.arbitrary()?,
                family: u.arbitrary()?,
                email: u.arbitrary()?,
            });
            ops.push(Op::Open {
                number: Id(0),
                kind: u.arbitrary()?,
                limit: u.arbitrary()?,
                customer: Id(0),
            });
        }
        for _ in 0..u.int_in_range(1..=MAX_STEPS)? {
            ops.push(u.arbitrary()?);
        }
        Ok(Self { ops })
    }
}

impl Script {
    /// Every step as the host dispatches it.
    #[must_use]
    pub fn steps(&self) -> Vec<(&'static str, Value)> {
        self.ops.iter().map(Op::render).collect()
    }
}
