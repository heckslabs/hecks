//! Mirrors `QuerySpecification::Common::DSL`'s five option words
//! (`lib/hecksagain/query_specification/common/dsl.rb`) — `offset`/
//! `cursor`/`authorize`/`nulls`/`inspect_query`. Shared verbatim by
//! `parse::query` and `parse::read_model`, since both Ruby builders
//! `include QuerySpecification::Common::DSL` and land on the identical
//! `ir::QueryOptions` shape (`ir.rs`'s own header explains why that's a
//! typed struct rather than a second alphabetically-ordered
//! `BTreeMap`). Confirmed real by banking.bluebook: `SafeDepositBox
//! .Rented`'s own `authorize :vault_access, tenant: :branch_code`.
//! `offset`/`cursor`/`nulls`/`inspect_query` are NOT exercised by any real
//! corpus member yet — built anyway, the same "correct even if
//! unreachable today" basis `emit.rs`'s own entity/process-manager
//! renderers already used before Stage 4 exercised THEM for real.
//! `consistency`/`freshness`/`use_index` are GONE (ADR 0025, "reads") —
//! declared and parsed by nothing but the HTML form renderer, so they
//! failed the corpus-use-and-doctest bar and were deleted rather than
//! deprecated.

use crate::diag::ParseResult;
use crate::ir;
use crate::parse::{self, ArgumentGateResult};
use crate::ruby_value;

/// Applies one already-gated option call onto `options` — `word` is one
/// of the five this module's own header names; `context` (`"Query"` or
/// `"ReadModel"`) is passed through only for `positional_symbol`'s own
/// diagnostic wording, since the two contexts declare IDENTICAL argument
/// shapes for every one of these words.
pub fn apply(file: &str, line: usize, word: &str, args: &ArgumentGateResult, options: &mut ir::QueryOptions) -> ParseResult<()> {
    match word {
        // `OffsetSpec`/`CursorSpec#to_h`'s own `{value: render_value(value)}`
        // — the SAME "already-rendered text" shape `ir::LimitSpec.value`
        // uses, regardless of the argument's own declared lexical `kind`
        // (a number for `offset`, a symbol for `cursor` per
        // syntax.bluebook's own rows) — `ruby_value::read`/`render`
        // round-trips either one correctly without needing to know which.
        "offset" => options.offset = Some(rendered_positional(args, 1)),
        "cursor" => options.cursor = Some(rendered_positional(args, 1)),
        // `AuthorizationSpec#to_h` — BOTH fields bare `.to_s` (never
        // Literal-rendered): `policy`/`tenant` a Symbol's plain name, no
        // leading colon. `positional_symbol`/`named_symbol` already strip
        // it, so no extra rendering step is needed here.
        "authorize" => {
            let policy = parse::positional_symbol(file, line, word, args, 1)?;
            let tenant = parse::named_symbol(args, "tenant");
            options.authorization = Some(ir::AuthorizationSpec { policy, tenant });
        }
        // `NullSemantics#to_h`'s `mode.to_s` — `extra_options_to_h` drops
        // the key entirely when it equals the default (`{mode: "native"}`),
        // so a `nulls :native` line is legal but leaves `null_semantics`
        // `None`, the same as never having written the line at all.
        "nulls" => {
            let mode = parse::positional_symbol(file, line, word, args, 1)?;
            if mode != "native" {
                options.null_semantics = Some(mode);
            }
        }
        // `def inspect_query(mode = :sql)` — the one option word whose
        // positional argument is genuinely OPTIONAL (`required: "false"`
        // in syntax.bluebook), defaulting to `:sql` when omitted.
        "inspect_query" => {
            let mode = match args.positional.iter().find(|(idx, _)| *idx == 1) {
                Some((_, text)) => text.trim().trim_start_matches(':').to_string(),
                None => "sql".to_string(),
            };
            options.inspection = Some(mode);
        }
        other => unreachable!("build::query_options::apply called with an unhandled word: {other}"),
    }
    Ok(())
}

fn rendered_positional(args: &ArgumentGateResult, at: usize) -> String {
    args.positional.iter().find(|(idx, _)| *idx == at).map(|(_, text)| rendered(text)).unwrap_or_default()
}

fn rendered(raw: &str) -> String {
    ruby_value::render(&ruby_value::read(raw.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args_with(positional: Vec<(usize, &str)>, named: Vec<(&str, &str)>) -> ArgumentGateResult {
        ArgumentGateResult {
            positional: positional.into_iter().map(|(i, t)| (i, t.to_string())).collect(),
            named: named.into_iter().map(|(n, v)| (n.to_string(), v.to_string())).collect(),
        }
    }

    #[test]
    fn applies_authorize_with_a_tenant() {
        let mut options = ir::QueryOptions::default();
        let args = args_with(vec![(1, ":vault_access")], vec![("tenant", ":branch_code")]);
        apply("f.bluebook", 1, "authorize", &args, &mut options).unwrap();
        let a = options.authorization.unwrap();
        assert_eq!(a.policy, "vault_access");
        assert_eq!(a.tenant, Some("branch_code".to_string()));
    }

    #[test]
    fn drops_the_default_null_semantics_mode() {
        let mut options = ir::QueryOptions::default();
        let args = args_with(vec![(1, ":native")], vec![]);
        apply("f.bluebook", 1, "nulls", &args, &mut options).unwrap();
        assert_eq!(options.null_semantics, None);
    }

    #[test]
    fn defaults_inspect_query_to_sql_with_no_argument() {
        let mut options = ir::QueryOptions::default();
        let args = args_with(vec![], vec![]);
        apply("f.bluebook", 1, "inspect_query", &args, &mut options).unwrap();
        assert_eq!(options.inspection, Some("sql".to_string()));
    }
}
