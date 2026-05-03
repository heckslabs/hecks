    /// The canonical Bluebook grammar — used by `parser::parse` until
    /// a domain explicitly declares one via `block_grammar "Bluebook"
    /// do ... end`. Mirrors `bluebook/grammars/bluebook.grammar`
    /// declaration order. The specializer can regenerate this function
    /// from the .grammar bluebook ; it lives in code today as the
    /// kernel-floor bootstrap (the parser of bluebook can't itself
    /// require a parsed bluebook to run).
    pub fn canonical_bluebook() -> Self {
        Self {
            name: "Bluebook".into(),
            blocks: vec![
                entry("aggregate", BlockParser::Aggregate),
                entry("section", BlockParser::Section),
                entry("policy", BlockParser::Policy),
                entry("process_manager", BlockParser::ProcessManager),
                entry("cadence", BlockParser::Cadence),
                entry("fixture", BlockParser::Fixture),
            ],
        }
    }
