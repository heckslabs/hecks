//! storehouse_query — read-only query dispatch for use-case step phrases.
//!
//! Commands resolve through the lexicon (`storehouse_router::walk_phrases`
//! collects only commands) ; a query-tail step phrase like
//! `Plan::Story.by_sprint` can't, so `storehouse_router::route` delegates
//! query phrases here. This boots the conception's combined domain against
//! its per-domain world stores and runs the query through the same
//! `Runtime::resolve_query_qualified` path the `storehouse query` CLI uses.
//! Queries are pure reads — no policies fire, no LLM/world-server wiring.
//!
//! Public API:
//!   `is_query_phrase(phrase)` — true when the dot-tail is snake_case
//!   `query_route(phrase, _args)` — resolve + run the query, 0 on a match
//!
//! Example:
//!   ```ignore
//!   use storehouse::storehouse_query;
//!   assert!(storehouse_query::is_query_phrase("Plan::Story.by_sprint"));
//!   let exit = storehouse_query::query_route("Plan::Story.by_sprint", &["sprint=1".into()]);
//!   ```

use crate::storehouse_router;

/// True when a phrase addresses a QUERY rather than a command. The phrase
/// shape is `Domain::Aggregate.tail` ; the tail's case decides: a command
/// tail is PascalCase (`Execute`), a query tail is snake_case (`by_sprint`,
/// `runnable`). A tail starting with an ASCII lowercase letter (or empty)
/// is treated as a query.
pub fn is_query_phrase(phrase: &str) -> bool {
    match phrase.rsplit_once('.') {
        Some((_head, tail)) => tail
            .chars()
            .next()
            .map_or(false, |c| c.is_ascii_lowercase()),
        None => false,
    }
}

/// Resolve and run a query-tail phrase. Returns 0 when the query resolves
/// against some aggregate (a non-error read, regardless of row count), 4
/// when no matching aggregate/query is found. `args` are `k=v` filter
/// tokens (value may contain spaces — split on the first `=` only).
pub fn query_route(phrase: &str, args: &[String]) -> i32 {
    let (head, tail) = match phrase.rsplit_once('.') {
        Some(parts) => parts,
        None => { eprintln!("storehouse query: '{}' is not Domain::Aggregate.query", phrase); return 1; }
    };
    let segments: Vec<&str> = head.split("::").collect();
    if segments.len() != 2 {
        eprintln!("storehouse query: '{}' is not a fully-qualified Domain::Aggregate.query phrase", phrase);
        return 1;
    }
    let agg = segments[1];

    // Boot the conception's combined domain against per-domain world stores
    // so the query reads the same heki the matching command wrote.
    let conception = storehouse_router::conception_root();
    let agg_dir = format!("{}/aggregates", conception);
    let domain = crate::corpus_loader::load_combined_domain(&agg_dir);
    let mut rt = crate::runtime::Runtime::boot_with_data_dir(domain, Some(agg_dir.clone()));
    crate::world::attach::apply_per_domain_world_dirs(&mut rt, &agg_dir);

    // Match the snake_case (or exact) tail against the aggregate's queries,
    // resolving through the context+aggregate-qualified path so a
    // same-named query on another aggregate doesn't shadow this one.
    let q_match = rt.domain.aggregates.iter()
        .filter(|a| a.name == agg)
        .find_map(|a| a.queries.iter()
            .find(|q| crate::heki::snake_case(&q.name) == tail || q.name == tail)
            .map(|q| (a.context.clone(), a.name.clone(), q.name.clone())));
    let (ctx, agg_name, q_name) = match q_match {
        Some(m) => m,
        None => {
            eprintln!("storehouse query: no query '{}' on aggregate '{}'", tail, agg);
            return 4;
        }
    };

    let attrs: std::collections::HashMap<String, String> = args.iter()
        .filter_map(|a| {
            let mut parts = a.splitn(2, '=');
            let k = parts.next()?;
            let v = parts.next()?;
            Some((k.to_string(), v.to_string()))
        })
        .collect();
    let result = rt.resolve_query_qualified(ctx.as_deref(), &agg_name, &q_name, &attrs);
    println!("{}", result);
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pascal_tail_is_command_not_query() {
        assert!(!is_query_phrase("Plan::Story.Execute"));
        assert!(!is_query_phrase("Plan::Story.Forward"));
    }

    #[test]
    fn snake_tail_is_query() {
        assert!(is_query_phrase("Plan::Story.by_sprint"));
        assert!(is_query_phrase("Plan::Story.runnable"));
        assert!(is_query_phrase("Plan::UseCase.for_story"));
    }

    #[test]
    fn no_dot_is_not_a_query() {
        assert!(!is_query_phrase("NotAPhrase"));
    }
}
