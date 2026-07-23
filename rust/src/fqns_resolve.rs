// fqns_resolve.rs — resolve a BARE dispatch ref ("Aggregate.verb", no `::`
// prefix) to its canonical realm-qualified FQN, or report why it can't be
// resolved SAFELY. The Phase-4 companion to the prefix sweep in `storehouse
// fqns`: that sweep rewrites quoted 2-seg refs (`Bluebook::Aggregate.verb`)
// whose prefix is realm-unambiguous, but it SKIPS bare 1-seg refs because a
// bare name carries no bluebook/realm to anchor on. This module resolves them
// by VERB : among every aggregate sharing the bare name, only those that
// actually declare the command/query are candidates ; if exactly one canonical
// address survives, the ref resolves ; otherwise it REFUSES rather than guess.
// Refuse-by-default is the silent-mis-resolve guard the migration plan calls
// for — a homonym that the verb cannot disambiguate is reported, never rewritten.
//
// Canonical address is built the SAME way the `fqns` prefix map builds it
// (realm_path → PascalCase `::` chain, then context (bluebook), then aggregate),
// so a bare-ref rewrite lands byte-identical to what the resolver enforces.

use crate::ir::Domain;

/// PascalCase a snake/lower folder segment (`agent_inbox` → `AgentInbox`).
fn pascal(seg: &str) -> String {
    seg.split('_')
        .map(|w| {
            let mut c = w.chars();
            c.next()
                .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
                .unwrap_or_default()
        })
        .collect()
}

/// The canonical realm-qualified PREFIX for an aggregate —
/// `Realm::Context…::Bluebook::Aggregate` — or None when the aggregate lacks a
/// stamped realm_path or a context (bluebook), in which case it can't anchor a
/// canonical address. Mirrors the formula in main.rs's `fqns` prefix builder.
pub fn canonical_prefix(agg: &crate::ir::Aggregate) -> Option<String> {
    let rp = agg.realm_path.as_deref()?;
    let bluebook = agg.context.clone().unwrap_or_default();
    if bluebook.is_empty() {
        return None;
    }
    let realm_ctx = rp.split('/').map(pascal).collect::<Vec<_>>().join("::");
    Some(format!("{}::{}::{}", realm_ctx, bluebook, agg.name))
}

/// Does this aggregate declare `verb` as a command or query? Commands match by
/// exact name (PascalCase) ; queries match by snake_case OR exact name (a bare
/// query ref is written snake_case, e.g. `Synapse.cold`).
fn declares_verb(agg: &crate::ir::Aggregate, verb: &str) -> bool {
    agg.commands.iter().any(|c| c.name == verb)
        || agg
            .queries
            .iter()
            .any(|q| q.name == verb || crate::util::snake_case(&q.name) == verb)
}

/// The verdict for one bare ref.
#[derive(Debug, PartialEq, Eq)]
pub enum BareResolution {
    /// Exactly one canonical address declares the verb — the full canonical
    /// ref (`Realm::…::Bluebook::Aggregate.verb`).
    Resolved(String),
    /// >1 distinct canonical address declares the verb — the candidates, for a
    /// > human (or a future local-context tier) to disambiguate. Never rewritten.
    Ambiguous(Vec<String>),
    /// Aggregate(s) with that name exist, but none declares the verb — the ref
    /// is stale or not actually a dispatch (e.g. an example in a comment).
    VerbNotFound,
    /// No aggregate has that name — not a corpus dispatch ref (junk / example).
    UnknownAggregate,
}

/// Resolve a bare `agg_name.verb` against the loaded corpus. Verb-disambiguated,
/// refuse-by-default. `agg_name` is the bare PascalCase aggregate ; `verb` is
/// the dot-tail (command PascalCase or query snake_case).
pub fn resolve_bare(domain: &Domain, agg_name: &str, verb: &str) -> BareResolution {
    let by_name: Vec<&crate::ir::Aggregate> =
        domain.aggregates.iter().filter(|a| a.name == agg_name).collect();
    if by_name.is_empty() {
        return BareResolution::UnknownAggregate;
    }
    let mut canonicals: Vec<String> = by_name
        .iter()
        .filter(|a| declares_verb(a, verb))
        .filter_map(|a| canonical_prefix(a))
        .collect();
    canonicals.sort();
    canonicals.dedup();
    match canonicals.len() {
        0 => BareResolution::VerbNotFound,
        1 => BareResolution::Resolved(format!("{}.{}", canonicals[0], verb)),
        _ => BareResolution::Ambiguous(canonicals),
    }
}

/// Extract bare dotted refs — `"Aggregate.verb"` quoted tokens with NO `::` —
/// from a source string. Returns (agg, verb, full_token_without_quotes) per
/// occurrence (dedup is the caller's job). The quote anchor is what keeps an
/// already-canonical `"R::C::B::Agg.verb"` from matching (its char before `Agg`
/// is `:`, not `"`).
pub fn extract_bare_refs(content: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let bytes = content.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'"' {
            i += 1;
            continue;
        }
        // Find the closing quote.
        let start = i + 1;
        let mut j = start;
        while j < bytes.len() && bytes[j] != b'"' {
            j += 1;
        }
        if j >= bytes.len() {
            break;
        }
        let tok = &content[start..j];
        if is_bare_ref(tok) {
            if let Some((agg, verb)) = tok.split_once('.') {
                out.push((agg.to_string(), verb.to_string()));
            }
        }
        i = j + 1;
    }
    out
}

/// A token is a bare dotted ref when : no `::`, exactly one `.`, the head is a
/// PascalCase identifier, and the tail is a (snake/Pascal) identifier. Excludes
/// file names, versioned strings, and already-qualified refs.
fn is_bare_ref(tok: &str) -> bool {
    if tok.contains("::") {
        return false;
    }
    let Some((head, tail)) = tok.split_once('.') else {
        return false;
    };
    if head.is_empty() || tail.is_empty() || tail.contains('.') {
        return false;
    }
    let head_ok = head.chars().next().is_some_and(|c| c.is_ascii_uppercase())
        && head.chars().all(|c| c.is_ascii_alphanumeric());
    let tail_ok = tail
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_');
    head_ok && tail_ok
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC: &str = r#"
Hecks.bluebook "Framework" do
  aggregate "SearchTool" do
    attribute :id, Id
    command "Grep" do
      attribute :id, Id
    end
  end
  aggregate "Inbox" do
    attribute :id, Id
    command "Check" do
      attribute :id, Id
    end
  end
end
"#;

    fn domain() -> Domain {
        let mut d = crate::parser::parse(SRC);
        // Stamp realm_path as the loader would (folder chain).
        for a in d.aggregates.iter_mut() {
            a.realm_path = Some("hecks/framework".to_string());
        }
        d
    }

    #[test]
    fn unique_name_resolves() {
        let d = domain();
        assert_eq!(
            resolve_bare(&d, "SearchTool", "Grep"),
            BareResolution::Resolved("Hecks::Framework::Framework::SearchTool.Grep".into())
        );
    }

    #[test]
    fn unknown_aggregate() {
        let d = domain();
        assert_eq!(resolve_bare(&d, "Nope", "X"), BareResolution::UnknownAggregate);
    }

    #[test]
    fn verb_not_found() {
        let d = domain();
        assert_eq!(resolve_bare(&d, "SearchTool", "Nope"), BareResolution::VerbNotFound);
    }

    #[test]
    fn extract_skips_qualified_and_nonrefs() {
        let refs = extract_bare_refs(r#" dispatch "Body.WakeUp" ; x "R::C::B::Agg.verb" ; "file.txt" "#);
        assert!(refs.contains(&("Body".to_string(), "WakeUp".to_string())));
        // qualified ref not matched as bare
        assert!(!refs.iter().any(|(a, _)| a == "R"));
        // lowercase head (file.txt) not a bare ref
        assert!(!refs.iter().any(|(a, _)| a == "file"));
    }

    #[test]
    fn ambiguous_when_two_canonicals_declare_verb() {
        let mut d = domain();
        // Clone SearchTool into a second realm/context, both declaring Grep.
        let mut other = d.aggregates.iter().find(|a| a.name == "SearchTool").unwrap().clone();
        other.realm_path = Some("miette/body".to_string());
        other.context = Some("Body".to_string());
        d.aggregates.push(other);
        match resolve_bare(&d, "SearchTool", "Grep") {
            BareResolution::Ambiguous(cands) => assert_eq!(cands.len(), 2),
            other => panic!("expected Ambiguous, got {:?}", other),
        }
    }
}
