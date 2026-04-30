    pub fn find(&self, id: &str) -> Option<&AggregateState> {
        self.store.get(id)
    }
