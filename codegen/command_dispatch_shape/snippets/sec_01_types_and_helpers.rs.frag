#[derive(Debug, Clone)]
pub struct CommandResult {
    pub aggregate_id: String,
    pub aggregate_type: String,
    pub event: Option<Event>,
    /// Event-sourcing deltas (i-event-sourcing) — the fields this command
    /// actually changed, computed as a before/after diff of aggregate state
    /// (so a lifecycle transition is just another changed field, no special-
    /// casing). `record_event_append` appends one immutable Event to the Log
    /// per delta. Empty for synthetic events and bulk-form dispatch (v1).
    pub deltas: Vec<(String, Value)>,
}

/// Resolution of a dispatch address — i111-J.
///
/// `Aggregate(agg_idx, cmd_idx)` — command lives directly on the
/// aggregate's commands list.
///
/// `Entity(agg_idx, ent_idx, cmd_idx)` — command lives inside an
/// entity declared inside the aggregate's `entity "Foo" do … end`
/// block. Dispatch still operates on the parent aggregate's record
/// (entities are reached only through the root in DDD), but uses the
/// entity's command — its mutations, givens, lifecycle.
#[derive(Debug, Clone, Copy)]
enum Resolution {
    Aggregate(usize, usize),
    Entity(usize, usize, usize),
}

impl Resolution {
    fn agg_idx(&self) -> usize {
        match self {
            Resolution::Aggregate(a, _) => *a,
            Resolution::Entity(a, _, _) => *a,
        }
    }
}

/// Borrow the resolved command from the runtime's IR.
fn cmd_for<'a>(rt: &'a Runtime, res: Resolution) -> &'a Command {
    match res {
        Resolution::Aggregate(a, c) => &rt.domain.aggregates[a].commands[c],
        Resolution::Entity(a, e, c) => &rt.domain.aggregates[a].entities[e].commands[c],
    }
}

/// Borrow the lifecycle that gates the resolved command : the entity's
/// own lifecycle when present, otherwise the parent aggregate's.
fn lifecycle_for<'a>(rt: &'a Runtime, res: Resolution) -> Option<&'a Lifecycle> {
    match res {
        Resolution::Aggregate(a, _) => rt.domain.aggregates[a].lifecycle.as_ref(),
        Resolution::Entity(a, e, _) => rt.domain.aggregates[a].entities[e]
            .lifecycle
            .as_ref()
            .or(rt.domain.aggregates[a].lifecycle.as_ref()),
    }
}
