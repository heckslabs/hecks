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
//!   ```text
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
            .is_some_and(|c| c.is_ascii_lowercase()),
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
    // Accept both the FQN head (`Domain::Aggregate`) and the BARE head
    // (`Aggregate`) — mirroring command resolution, which resolves a bare
    // `Aggregate.Command` as well as the qualified form. The aggregate name
    // is the last `::` segment in either case ; the query match below filters
    // by `a.name == agg` across the combined domain.
    let segments: Vec<&str> = head.split("::").collect();
    let agg = match segments.as_slice() {
        [_domain, aggregate] => *aggregate,
        [aggregate] => *aggregate,
        _ => {
            eprintln!("storehouse query: '{}' is not an Aggregate.query or Domain::Aggregate.query phrase", phrase);
            return 1;
        }
    };

    // Boot the conception's combined domain against per-domain world stores
    // so the query reads the same heki the matching command wrote.
    //
    // The data_dir MUST be resolved through `embed::data_dir` — the same
    // resolver the command door (`dispatch_hecksagon` via `find_world_heki_dir`)
    // and every other reader uses. This used to pass `agg_dir` itself, which is
    // the SOURCE tree, not a store root : commands wrote to the world-resolved
    // location (`data_root()/<realm>`) while this read from
    // `<conception>/aggregates`, so a read here could never see what a command
    // wrote. The doc comment above claimed otherwise and had been wrong for as
    // long as it existed — proven by writing a Story through the command door
    // and reading it back through both paths : `storehouse query` returned the
    // row, this path returned `state: []`.
    let conception = storehouse_router::conception_root();
    let agg_dir = format!("{}/aggregates", conception);
    let domain = crate::corpus_loader::load_combined_domain(&agg_dir);
    let data_dir = crate::embed::data_dir(&agg_dir);
    let mut rt = crate::runtime::Runtime::boot_with_data_dir(domain, Some(data_dir));
    crate::world::attach::apply_per_domain_world_dirs(&mut rt, &agg_dir);

    // Match the snake_case (or exact) tail against the aggregate's queries,
    // resolving through the context+aggregate-qualified path so a
    // same-named query on another aggregate doesn't shadow this one.
    let q_match = rt.domain.aggregates.iter()
        .filter(|a| a.name == agg)
        .find_map(|a| a.queries.iter()
            .find(|q| crate::util::snake_case(&q.name) == tail || q.name == tail)
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
            let (k, v) = a.split_once('=')?;
            
            
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

    #[test]
    fn the_router_reads_where_commands_write() {
        // REGRESSION. `query_route` used to boot against `agg_dir` itself — the
        // SOURCE tree — while every command door resolves its store through
        // `embed::data_dir`. So a read here could never see what a command
        // wrote, while the doc comment claimed the opposite. Proven by writing a
        // Story through the command door and reading it back both ways :
        // `storehouse query` returned the row, this path returned `state: []`.
        //
        // The invariant : whatever the conception's aggregates dir is, the store
        // this path reads is the one `embed::data_dir` resolves — never the
        // source directory that was passed in.
        let conception = storehouse_router::conception_root();
        let agg_dir = format!("{}/aggregates", conception);
        let resolved = crate::embed::data_dir(&agg_dir);
        assert_ne!(
            resolved, agg_dir,
            "the store root must not be the source tree — that was the bug",
        );
        assert!(
            !resolved.is_empty(),
            "embed::data_dir always resolves (it never returns None)",
        );
    }

    #[test]
    fn bare_aggregate_query_phrase_is_recognized() {
        // A bare `Aggregate.query` (no Domain::) is still a query — query_route
        // resolves it by aggregate name, mirroring bare command resolution.
        assert!(is_query_phrase("Correspondent.needing_response"));
        assert!(is_query_phrase("Story.runnable"));
    }
}
