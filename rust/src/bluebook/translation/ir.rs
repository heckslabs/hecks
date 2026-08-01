//! IR for `Hecks.data_translation` — mirrors
//! lib/hecksagain/bluebook/ir/translation.rb exactly. Renames, moves
//! across a value-object boundary, value conversions, and deliberate
//! drops, declared per aggregate.

#[derive(Debug, Clone)]
pub struct TranslationMove {
    pub from: String,
    pub to: String,
}

/// A value literal as it appeared in a `convert`'s `values:` table —
/// typed, not just text, so a boolean or integer key matches the raw
/// stored value it actually is rather than always requiring a string.
#[derive(Debug, Clone, PartialEq)]
pub enum ConvertLiteral {
    Str(String),
    Bool(bool),
    Int(i64),
}

impl ConvertLiteral {
    /// Parses one `values:` token: a quoted string, `true`/`false`, an
    /// integer, or — falling back — the bare text itself.
    pub fn parse(token: &str) -> Self {
        let t = token.trim();
        if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
            return Self::Str(t[1..t.len() - 1].to_string());
        }
        match t {
            "true" => Self::Bool(true),
            "false" => Self::Bool(false),
            _ => t.parse::<i64>().map(Self::Int).unwrap_or_else(|_| Self::Str(t.to_string())),
        }
    }

    /// Renders the way Ruby's `.inspect` would — a quoted string stays
    /// quoted, a bool or int is bare — so a refusal naming an unmapped
    /// value reads identically in both runtimes.
    pub fn render(&self) -> String {
        match self {
            Self::Str(s) => format!("{s:?}"),
            Self::Bool(b) => b.to_string(),
            Self::Int(i) => i.to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TranslationConvert {
    pub from: String,
    pub to: String,
    pub values: Vec<(ConvertLiteral, ConvertLiteral)>,
}

/// A value object's or entity's own TYPE NAME changed with its member
/// structure unchanged — mirrors `was:` one level deeper. Stored data
/// never carries the type name, so nothing moves; the declaration only
/// satisfies the era diff's literal type-name comparison.
#[derive(Debug, Clone, PartialEq)]
pub struct TranslationRetype {
    pub from: String,
    pub to: String,
}

/// A computed transform — rescale, reformat, split, merge — whose only
/// implementation is the SQL expression itself, evaluated exclusively
/// inside the compiled Postgres head. No in-process reference exists to
/// check it against; any aggregate carrying one refuses to boot on
/// every other adapter.
#[derive(Debug, Clone, PartialEq)]
pub struct TranslationCompute {
    pub from: String,
    pub to: String,
    pub sql: String,
}

#[derive(Debug, Clone, Default)]
pub struct TranslationAggregate {
    pub name: String,
    pub was: Option<String>,
    pub renames: Vec<(String, String)>,
    pub moves: Vec<TranslationMove>,
    pub converts: Vec<TranslationConvert>,
    pub drops: Vec<String>,
    pub retypes: Vec<TranslationRetype>,
    pub computes: Vec<TranslationCompute>,
}

impl TranslationAggregate {
    fn top_level(path: &str) -> &str {
        path.split('.').next().unwrap_or(path)
    }

    /// Whether this aggregate's translation names `path` as an old key it
    /// accounts for — the rename, move, or convert it came from, or an
    /// explicit drop. `path` may be a bare name ("cost") or a dotted
    /// value-object member ("price.currency"); a rule covering the whole
    /// top-level attribute covers anything nested under it too.
    pub fn explains(&self, path: &str) -> bool {
        let top = Self::top_level(path);
        self.renames.iter().any(|(old, _)| old == top)
            || self.moves.iter().any(|m| m.from == path || Self::top_level(&m.from) == top)
            || self.converts.iter().any(|c| c.from == path || Self::top_level(&c.from) == top)
            || self.drops.iter().any(|d| d == path || Self::top_level(d) == top)
            || self.computes.iter().any(|c| c.from == path || Self::top_level(&c.from) == top)
    }
}

#[derive(Debug, Clone, Default)]
pub struct Translation {
    pub domain: String,
    pub from: String,
    pub to: String,
    pub aggregates: Vec<TranslationAggregate>,
    /// Aggregates that are gone outright — not renamed. The deliberate
    /// alternative to a bogus `was:` claim on an unrelated aggregate.
    pub retired: Vec<String>,
}

impl Translation {
    pub fn for_aggregate(&self, name: &str) -> Option<&TranslationAggregate> {
        self.aggregates.iter().find(|aggregate| aggregate.name == name)
    }
}
