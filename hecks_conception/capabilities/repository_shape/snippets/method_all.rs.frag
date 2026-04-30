    pub fn all(&self) -> Vec<&AggregateState> {
        self.store.values().collect()
    }
