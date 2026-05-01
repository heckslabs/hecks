    pub fn new(
        aggregate_type: &str,
        data_dir: Option<String>,
        identified_by: Option<String>,
    ) -> Self {
        Self::new_with_context(aggregate_type, data_dir, identified_by, None)
    }
