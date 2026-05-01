    pub fn new(id: &str) -> Self {
        AggregateState {
            id: id.to_string(),
            fields: HashMap::new(),
            deleted: false,
        }
    }
