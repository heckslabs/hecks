/// Sprint 14 — per-aggregate event-delivery mode (`migration-coexistence`
/// story). Declared in the bluebook as `delivery :sync` (default) or
/// `delivery :actor`. The runtime forks at every event-publish site :
/// `Sync` publishes inline as today ; `Actor` enqueues into the
/// per-aggregate mailbox stub first, then drains.
///
/// The `Actor` arm is a stub today (enqueue → drain immediately in the
/// same call) so this story's wiring is independently verifiable while
/// the real async-bus + per-actor mailbox work lands under sibling
/// sprint-14 stories `actor-per-aggregate-instance` and
/// `async-event-delivery-bus`. The fork is the contract ; the runtime
/// behind it can mature without touching any bluebook.
///
/// Deliberately NOT serialised in `dump.rs` / `canonical_ir.rb` :
/// delivery is a runtime-routing concern, not part of the public IR
/// contract — parity stays byte-equal across every existing fixture
/// because both Ruby and Rust dumpers omit the field unconditionally.
