    /// Sprint 14 (`wire-mailbox-registry-into-event-bus`) — publish an
    /// event through the per-aggregate mailbox. After
    /// `retire-sync-cascade-pipeline`, dispatch publishes inline rather
    /// than calling this entry point ; the mailbox-registry wiring
    /// tests still drive it directly to pin the per-mailbox FIFO +
    /// cross-aggregate parallelism contract that the actor-per-
    /// aggregate-instance + async-event-delivery-bus stories will lift
    /// back into dispatch. The flow :
    ///
    ///   1. Wrap the event in an `Envelope`. The bus-side event_id is
    ///      the event-name + aggregate-id + monotonic counter so the
    ///      mailbox's seen-set can dedupe duplicates by construction.
    ///   2. `Mailboxes::deliver` enqueues the envelope at address
    ///      `(aggregate_type, aggregate_id)`, lazy-creating the mailbox
    ///      on first delivery (per actor-per-aggregate-instance). The
    ///      return value tells us whether the event_id was fresh ; a
    ///      duplicate is dropped at the mailbox boundary and we don't
    ///      publish.
    ///   3. Drain the addressed mailbox synchronously on this thread,
    ///      publishing each popped envelope through `event_bus.publish`.
    ///      Causal-ordering-per-aggregate is the mailbox's FIFO ;
    ///      sync-feel command dispatch is preserved because the drain
    ///      happens before `enqueue_and_drain` returns. Cross-aggregate
    ///      parallelism (event on A while slow handler runs on B → A
    ///      not blocked) is realised by `drain_all_in_parallel` in the
    ///      registry — exercised by the `actor::tests` unit suite and
    ///      smoke decision #5 in `bin/sprint14-smoke`.
    ///
    /// The `mailbox_drained` counter still increments — behaviors tests
    /// + the migration-coexistence integration test depend on it as the
    /// "actor arm fired" proof — but it is no longer the contract. The
    /// contract is the mailbox itself : per-aggregate FIFO + idempotency
    /// + failure isolation are now properties of the bus, not aspirations.
    pub fn enqueue_and_drain(&mut self, event: Event) {
        self.mailbox_drained = self.mailbox_drained.saturating_add(1);
        let addr: actor::ActorAddress = (event.aggregate_type.clone(), event.aggregate_id.clone());
        let event_id = format!(
            "{}::{}::{}::{}",
            event.aggregate_type,
            event.aggregate_id,
            event.name,
            self.mailbox_drained,
        );
        let envelope = actor::Envelope::new(event, event_id);
        let accepted = self.mailbox_registry.deliver(addr.clone(), envelope);
        if !accepted {
            return;
        }
        let mailbox_arc = match self.mailbox_registry.mailbox_for(&addr) {
            Some(mb) => mb,
            None => return,
        };
        // Drain the addressed mailbox in FIFO order, publishing each
        // envelope through the existing event bus. Holding the mutex
        // for the whole drain keeps causal ordering for this address
        // ; sibling addresses' mailboxes are independent and a
        // concurrent caller could drain them in parallel via
        // `mailbox_registry.drain_all_in_parallel` (used by tests).
        let popped: Vec<actor::Envelope> = {
            let mut guard = mailbox_arc.lock().expect("mailbox mutex poisoned");
            if guard.status == actor::MailboxStatus::Poisoned {
                return;
            }
            let mut out = Vec::new();
            while let Some(env) = guard.pop() { out.push(env); }
            out
        };
        for env in popped {
            self.event_bus.publish(env.event.clone());
            let mut guard = mailbox_arc.lock().expect("mailbox mutex poisoned");
            guard.note_handled();
        }
    }
