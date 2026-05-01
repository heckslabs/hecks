#[derive(Debug, Clone)]
pub struct AggregateState {
    pub id: String,
    pub fields: HashMap<String, Value>,
    /// Set true by a `then_delete` mutation. The command dispatcher
    /// checks this after `apply_mutations` and calls
    /// `Repository::delete` instead of `Repository::save` when
    /// present. Default false ; only retire-style commands flip it.
    pub deleted: bool,
}

