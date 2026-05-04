    /// Resolve a parser-name string (as declared in the bluebook
    /// grammar) to a typed BlockParser variant. None when the name is
    /// unknown — the bluebook grammar can't reach functions that
    /// haven't been linked into the binary.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "parse_aggregate" => Some(Self::Aggregate),
            "parse_policy" => Some(Self::Policy),
            "parse_process_manager" => Some(Self::ProcessManager),
            "parse_cadence" => Some(Self::Cadence),
            "parse_section" => Some(Self::Section),
            "parse_fixture" => Some(Self::Fixture),
            _ => None,
        }
    }

    /// Stable string name (round-trips through `from_name`). Used by
    /// dump.rs / canonical_ir.rb so the parity contract carries the
    /// declared parser identity rather than a Rust-only enum tag.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Aggregate => "parse_aggregate",
            Self::Policy => "parse_policy",
            Self::ProcessManager => "parse_process_manager",
            Self::Cadence => "parse_cadence",
            Self::Section => "parse_section",
            Self::Fixture => "parse_fixture",
        }
    }
