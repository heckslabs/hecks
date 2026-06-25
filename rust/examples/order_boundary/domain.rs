//! Order domain — the PURE side of the boundary.
//!
//! [antibody-exempt: rust/examples/order_boundary/domain.rs — handwritten
//!  reference pattern for the code generator (sync-domain / async-adapter
//!  boundary, decided with Chris 2026-06-12). Retires when the specializer
//!  emits this projection from order.bluebook.]
//!
//! THE RULE THIS FILE EMBODIES : nothing asynchronous may appear here.
//! No tokio. No Mutex. No channel. No IO. No clock. No Result-of-network.
//! `decide` is a pure function from (current state, command) to
//! (next state, event) — the projection of order.bluebook's givens,
//! then_sets, lifecycle and emits. If a concern cannot be expressed as
//! data-in / data-out, it does not belong in this file ; it belongs in
//! an adapter behind the bus (see ports.rs).
//!
//! Mirrors order.bluebook exactly : Place is a FACTORY (mints, refuses
//! an existing ref) ; Authorize / Decline / Cancel are commands (load an
//! existing record, lifecycle-gated).

/// The aggregate state — plain data, the bluebook's attributes.
#[derive(Debug, Clone, PartialEq)]
pub struct Order {
    pub r#ref: String,
    pub customer_name: String,
    pub amount_cents: i64,
    pub status: Status,
    pub payment_ref: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Status {
    Pending,
    Authorized,
    Declined,
    Cancelled,
}

/// The utterances — one factory (birth), three commands (transitions).
/// The node KIND carries the create/transition bit, exactly as in the
/// runtime's two-path dispatch (first-class factories phase 2).
#[derive(Debug, Clone)]
pub enum Utterance {
    /// FACTORY — births an Order ; the bus routes it down the mint path.
    Place { r#ref: String, customer_name: String, amount_cents: i64 },
    /// COMMAND — the gateway's APPROVED verdict re-entering synchronously.
    Authorize { r#ref: String, payment_ref: String },
    /// COMMAND — the gateway's DECLINED verdict. Same shape ; the
    /// adapter picked the branch, not the domain.
    Decline { r#ref: String, payment_ref: String },
    /// COMMAND — customer cancellation, only valid while pending.
    Cancel { r#ref: String },
}

/// Domain events — pure data composed by `decide`, executed by nobody
/// here. The bus hands them to effect adapters ; the domain never
/// knows what listens.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub name: &'static str,
    pub order_ref: String,
}

#[derive(Debug, PartialEq)]
pub enum DomainError {
    /// A given refused the command (the bluebook's `given` block).
    GivenFailed(&'static str),
    /// Lifecycle gate : the transition is not legal from this status.
    LifecycleViolation { command: &'static str, current: Status },
}

/// THE pure function. Synchronous by construction — its signature is
/// the boundary contract. `current` is None only for the factory path
/// (the bus guarantees mint-vs-load before calling, mirroring
/// Resolution::Factory vs Resolution::Aggregate).
pub fn decide(current: Option<&Order>, utterance: &Utterance) -> Result<(Order, Event), DomainError> {
    match utterance {
        Utterance::Place { r#ref, customer_name, amount_cents } => {
            // given("amount must be positive") { amount_cents > 0 }
            if *amount_cents <= 0 {
                return Err(DomainError::GivenFailed("amount must be positive"));
            }
            let order = Order {
                r#ref: r#ref.clone(),
                customer_name: customer_name.clone(),
                amount_cents: *amount_cents,
                status: Status::Pending,
                payment_ref: None,
            };
            let event = Event { name: "OrderPlaced", order_ref: r#ref.clone() };
            Ok((order, event))
        }
        Utterance::Authorize { r#ref, payment_ref } => {
            let order = existing(current, "Authorize")?;
            gate(order, "Authorize", Status::Pending)?;
            let mut next = order.clone();
            next.status = Status::Authorized;
            next.payment_ref = Some(payment_ref.clone());
            Ok((next, Event { name: "OrderAuthorized", order_ref: r#ref.clone() }))
        }
        Utterance::Decline { r#ref, payment_ref } => {
            let order = existing(current, "Decline")?;
            gate(order, "Decline", Status::Pending)?;
            let mut next = order.clone();
            next.status = Status::Declined;
            next.payment_ref = Some(payment_ref.clone());
            Ok((next, Event { name: "OrderDeclined", order_ref: r#ref.clone() }))
        }
        Utterance::Cancel { r#ref } => {
            let order = existing(current, "Cancel")?;
            gate(order, "Cancel", Status::Pending)?;
            let mut next = order.clone();
            next.status = Status::Cancelled;
            Ok((next, Event { name: "OrderCancelled", order_ref: r#ref.clone() }))
        }
    }
}

/// The verb's natural key — lets the bus decide mint-vs-load without
/// the domain knowing storage exists.
pub fn target_ref(utterance: &Utterance) -> &str {
    match utterance {
        Utterance::Place { r#ref, .. }
        | Utterance::Authorize { r#ref, .. }
        | Utterance::Decline { r#ref, .. }
        | Utterance::Cancel { r#ref } => r#ref,
    }
}

/// True when the utterance is a birth (the bus routes mint-path).
pub fn is_factory(utterance: &Utterance) -> bool {
    matches!(utterance, Utterance::Place { .. })
}

fn existing<'a>(current: Option<&'a Order>, command: &'static str) -> Result<&'a Order, DomainError> {
    current.ok_or(DomainError::LifecycleViolation { command, current: Status::Cancelled })
}

/// The lifecycle gate — transitions are legal from `from` only.
fn gate(order: &Order, command: &'static str, from: Status) -> Result<(), DomainError> {
    if order.status != from {
        return Err(DomainError::LifecycleViolation { command, current: order.status });
    }
    Ok(())
}
