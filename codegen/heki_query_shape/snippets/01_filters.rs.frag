// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum FilterOp { Eq, NotEq, Prefix, Substring }

#[derive(Debug, Clone)]
pub struct Filter {
    pub field: String,
    pub op: FilterOp,
    pub value: String,
}

impl Filter {
    /// Parse a `--where k=v` / `k!=v` / `k~=v` / `k*=v` spec.
    /// Returns Err with a message on syntax error (exit code 2 territory).
    pub fn parse(spec: &str) -> Result<Self, String> {
        // Order matters — check two-char ops before '='.
        if let Some(i) = spec.find("!=") {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::NotEq,
                value: spec[i+2..].to_string(),
            });
        }
        if let Some(i) = spec.find("~=") {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::Prefix,
                value: spec[i+2..].to_string(),
            });
        }
        if let Some(i) = spec.find("*=") {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::Substring,
                value: spec[i+2..].to_string(),
            });
        }
        if let Some(i) = spec.find('=') {
            return Ok(Filter {
                field: spec[..i].to_string(),
                op: FilterOp::Eq,
                value: spec[i+1..].to_string(),
            });
        }
        Err(format!("invalid --where spec: {}", spec))
    }

    pub fn matches(&self, rec: &Record) -> bool {
        let val = field_to_string(rec.get(&self.field));
        match self.op {
            FilterOp::Eq        => val == self.value,
            FilterOp::NotEq     => val != self.value,
            FilterOp::Prefix    => val.starts_with(&self.value),
            FilterOp::Substring => val.contains(&self.value),
        }
    }
}

/// Apply every filter with AND semantics.
pub fn filter_records<'a>(store: &'a Store, filters: &[Filter]) -> Vec<&'a Record> {
    store.values()
        .filter(|r| filters.iter().all(|f| f.matches(r)))
        .collect()
}

