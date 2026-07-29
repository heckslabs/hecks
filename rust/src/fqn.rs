//! Public Bluebook command/query addresses.
//!
//! Realm comes from a world. `Domain@version` pins a domain contract; an
//! unpinned domain is the realm's active/latest alias. PascalCase verbs are
//! commands and snake_case verbs are queries.

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct Fqn {
    pub realm: Option<String>,
    pub domain: String,
    pub version: Option<String>,
    pub aggregate: String,
    pub verb: String,
    pub kind: Kind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum Kind {
    Command,
    Query,
}

impl Fqn {
    pub fn command(
        realm: Option<&str>,
        domain: &str,
        version: Option<&str>,
        aggregate: &str,
        command: &str,
    ) -> Result<Self, String> {
        Self::new(realm, domain, version, aggregate, command, Kind::Command)
    }

    pub fn query(
        realm: Option<&str>,
        domain: &str,
        version: Option<&str>,
        aggregate: &str,
        query: &str,
    ) -> Result<Self, String> {
        Self::new(realm, domain, version, aggregate, query, Kind::Query)
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        let (head, verb) = text
            .rsplit_once('.')
            .ok_or_else(|| format!("FQN must be Realm::Domain::Aggregate.verb — got {text:?}"))?;
        let segments: Vec<&str> = head.split("::").collect();
        if !matches!(segments.len(), 2 | 3)
            || segments.iter().any(|segment| segment.is_empty())
            || verb.is_empty()
        {
            return Err(format!(
                "FQN must be Realm::Domain::Aggregate.verb — got {text:?}"
            ));
        }
        let (realm, domain_spec, aggregate) = if segments.len() == 3 {
            (Some(segments[0]), segments[1], segments[2])
        } else {
            (None, segments[0], segments[1])
        };
        let (domain, version) = split_domain(domain_spec)?;
        let kind = if Self::command_name(verb) {
            Kind::Command
        } else if Self::query_name(verb) {
            Kind::Query
        } else {
            return Err(format!(
                "FQN verb must be PascalCase command or snake_case query — got {text:?}"
            ));
        };
        Self::new(realm, domain, version, aggregate, verb, kind)
    }

    pub fn command_name(name: &str) -> bool {
        let mut chars = name.chars();
        chars
            .next()
            .is_some_and(|character| character.is_ascii_uppercase())
            && chars.all(|character| character.is_ascii_alphanumeric())
    }

    pub fn query_name(name: &str) -> bool {
        let mut chars = name.chars();
        chars
            .next()
            .is_some_and(|character| character.is_ascii_lowercase())
            && chars.all(|character| {
                character.is_ascii_lowercase() || character.is_ascii_digit() || character == '_'
            })
    }

    pub fn command_p(&self) -> bool {
        self.kind == Kind::Command
    }
    pub fn query_p(&self) -> bool {
        self.kind == Kind::Query
    }

    fn new(
        realm: Option<&str>,
        domain: &str,
        version: Option<&str>,
        aggregate: &str,
        verb: &str,
        kind: Kind,
    ) -> Result<Self, String> {
        for (label, value) in [("domain", domain), ("aggregate", aggregate), ("verb", verb)] {
            valid_segment(label, value)?;
        }
        if let Some(realm) = realm {
            valid_segment("realm", realm)?;
        }
        if let Some(version) = version {
            valid_segment("version", version)?;
        }
        let valid = match kind {
            Kind::Command => Self::command_name(verb),
            Kind::Query => Self::query_name(verb),
        };
        if !valid {
            return Err(format!("{kind:?} FQN has an invalid verb {verb:?}"));
        }
        Ok(Self {
            realm: realm.map(str::to_string),
            domain: domain.to_string(),
            version: version.map(str::to_string),
            aggregate: aggregate.to_string(),
            verb: verb.to_string(),
            kind,
        })
    }
}

fn split_domain(value: &str) -> Result<(&str, Option<&str>), String> {
    let mut parts = value.split('@');
    let domain = parts.next().unwrap_or("");
    let version = parts.next();
    if domain.is_empty()
        || parts.next().is_some()
        || value.contains('@') && version.is_none_or(str::is_empty)
    {
        return Err(format!("FQN domain version is malformed: {value:?}"));
    }
    Ok((domain, version))
}

fn valid_segment(label: &str, value: &str) -> Result<(), String> {
    if value.is_empty() || value.contains("::") || value.contains('.') || value.contains('@') {
        return Err(format!(
            "FQN {label} cannot be empty or contain a separator"
        ));
    }
    Ok(())
}

impl std::fmt::Display for Fqn {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let domain = match &self.version {
            Some(version) => format!("{}@{}", self.domain, version),
            None => self.domain.clone(),
        };
        let head = match &self.realm {
            Some(realm) => format!("{realm}::{domain}::{}", self.aggregate),
            None => format!("{domain}::{}", self.aggregate),
        };
        write!(formatter, "{head}.{}", self.verb)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_are_pascal_case() {
        let fqn = Fqn::command(Some("Acme"), "Banking", None, "Account", "Credit").unwrap();
        assert_eq!(fqn.to_string(), "Acme::Banking::Account.Credit");
        assert!(fqn.command_p());
    }

    #[test]
    fn queries_are_snake_case() {
        let fqn = Fqn::query(Some("Acme"), "Banking", None, "Account", "in_good_standing").unwrap();
        assert_eq!(fqn.to_string(), "Acme::Banking::Account.in_good_standing");
        assert!(fqn.query_p());
    }

    #[test]
    fn parsing_pins_a_version_on_the_domain() {
        let fqn = Fqn::parse("Acme::Banking@v2::Account.Credit").unwrap();
        assert_eq!(fqn.realm.as_deref(), Some("Acme"));
        assert_eq!(fqn.domain, "Banking");
        assert_eq!(fqn.version.as_deref(), Some("v2"));
    }
}
