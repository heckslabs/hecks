//! Query option words (`offset`, `cursor`, `authorize`, `nulls`, `inspect_query`)
//! shared by `parse::query` and `parse::read_model`.

use crate::diag::ParseResult;
use crate::ir;
use crate::parse::{self, ArgumentGateResult};
use crate::ruby_value;

/// Applies one already-gated option call (`offset`, `cursor`, `authorize`, `nulls`,
/// `inspect_query`) onto `options`; `context` only words diagnostics.
pub fn apply(
    file: &str,
    line: usize,
    word: &str,
    args: &ArgumentGateResult,
    options: &mut ir::QueryOptions,
) -> ParseResult<()> {
    match word {
        // The value keeps its rendered text whatever its lexical kind. `on:` is only a
        // recognized named argument in ReadModel context (ADR 0055); the argument gate has
        // already refused an undeclared one, so `named_constant` finds nothing for Query.
        "offset" => {
            let target = parse::named_constant(args, "on").map(crate::build::naming::demodulise);
            options.offset = Some(ir::OffsetSpec {
                value: rendered_positional(args, 1),
                target,
            });
        }
        "cursor" => options.cursor = Some(rendered_positional(args, 1)),
        // Both fields are bare names, without the leading colon.
        "authorize" => {
            let policy = parse::positional_symbol(file, line, word, args, 1)?;
            let tenant = parse::named_symbol(args, "tenant");
            options.authorization = Some(ir::AuthorizationSpec { policy, tenant });
        }
        // `nulls :native` is the default, so it leaves `null_semantics` unset.
        "nulls" => {
            let mode = parse::positional_symbol(file, line, word, args, 1)?;
            if mode != "native" {
                options.null_semantics = Some(mode);
            }
        }
        // `mode` is the one optional positional; it defaults to `:sql`.
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
    args.positional
        .iter()
        .find(|(idx, _)| *idx == at)
        .map(|(_, text)| rendered(text))
        .unwrap_or_default()
}

fn rendered(raw: &str) -> String {
    ruby_value::render(&ruby_value::read(raw.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args_with(positional: Vec<(usize, &str)>, named: Vec<(&str, &str)>) -> ArgumentGateResult {
        ArgumentGateResult {
            positional: positional
                .into_iter()
                .map(|(i, t)| (i, t.to_string()))
                .collect(),
            named: named
                .into_iter()
                .map(|(n, v)| (n.to_string(), v.to_string()))
                .collect(),
        }
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
