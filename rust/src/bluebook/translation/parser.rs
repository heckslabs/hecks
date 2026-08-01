use super::ir::{ConvertLiteral, Translation, TranslationAggregate, TranslationCompute, TranslationConvert, TranslationMove, TranslationRetype};
use crate::bluebook::hecksagon_helpers::{between_quotes, split_top_level_commas};
use crate::bluebook::parser_helpers::{extract_kwarg_string, extract_string, extract_symbol};

/// A `kwarg: :symbol` reader. Lived in parser_helpers until the host
/// parser stopped needing it; the translation sublanguage still does.
fn extract_kwarg_symbol(line: &str, kwarg: &str) -> Option<String> {
    let needle = format!("{kwarg}:");
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    let rest = rest.strip_prefix(':')?;
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    let sym = rest[..end].trim().to_string();
    if sym.is_empty() {
        None
    } else {
        Some(sym)
    }
}

pub fn is_translation_source(source: &str) -> bool {
    for line in source.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        return t.starts_with("Hecks.data_translation");
    }
    false
}

/// Fallible on purpose. The old signature (`-> Translation`) silently
/// dropped any rule with a missing field from the parsed IR — a
/// malformed `rename :cost` (no `to:`) never became a rule and never
/// became an error, so the author's first hint was `EraGuard` refusing
/// coverage for something they believed they had covered. Every refusal
/// below is byte-identical to the `Malformed` message Ruby's
/// `TranslationBuilder` raises for the same omission.
pub fn parse(source: &str) -> Result<Translation, String> {
    let mut translation = Translation::default();
    let raw: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < raw.len() {
        let line = raw[i].trim();

        if line.is_empty() || line.starts_with('#') || line == "end" {
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.data_translation") {
            let domain = between_quotes(line).unwrap_or_default();
            if domain.is_empty() {
                return Err("a translation names no domain".to_string());
            }
            let from = extract_kwarg_string(line, "from").unwrap_or_default();
            if from.is_empty() {
                return Err(format!("{domain}'s translation says nothing about its origin era (from:)"));
            }
            let to = extract_kwarg_string(line, "to").unwrap_or_default();
            if to.is_empty() {
                return Err(format!("{domain}'s translation says nothing about its destination era (to:)"));
            }
            translation.domain = domain;
            translation.from = from;
            translation.to = to;
            i += 1;
            continue;
        }

        match first_word(line) {
            "aggregate" => {
                let (aggregate, consumed) = parse_aggregate(&raw[i..])?;
                translation.aggregates.push(aggregate);
                i += consumed;
            }
            "retired" => {
                let name = extract_string(line).unwrap_or_default();
                if name.is_empty() {
                    return Err("a retired needs an aggregate name".to_string());
                }
                translation.retired.push(name);
                i += 1;
            }
            word => {
                return Err(format!(
                    "a translation does not understand '{word}' — it declares aggregate blocks and retired aggregates"
                ));
            }
        }
    }

    Ok(translation)
}

fn parse_aggregate(lines: &[&str]) -> Result<(TranslationAggregate, usize), String> {
    let first = lines[0].trim();
    let name = between_quotes(first).unwrap_or_default();
    if name.is_empty() {
        return Err("an aggregate translation needs a name".to_string());
    }
    let mut aggregate = TranslationAggregate {
        name,
        was: extract_kwarg_string(first, "was"),
        ..Default::default()
    };

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line == "end" {
            depth -= 1;
            i += 1;
            continue;
        }
        if line.is_empty() || line.starts_with('#') {
            i += 1;
            continue;
        }
        if ends_with_do(line) {
            depth += 1;
            i += 1;
            continue;
        }

        parse_rule(line, &mut aggregate)?;
        i += 1;
    }

    Ok((aggregate, i))
}

fn parse_rule(line: &str, aggregate: &mut TranslationAggregate) -> Result<(), String> {
    match first_word(line) {
        "rename" => {
            let old = extract_symbol(before_kwarg(line, "to")).unwrap_or_default();
            if old.is_empty() {
                return Err("a rename needs a source name".to_string());
            }
            let new = extract_kwarg_symbol(line, "to").unwrap_or_default();
            if new.is_empty() {
                return Err("a rename needs a destination name (to:)".to_string());
            }
            aggregate.renames.push((old, new));
        }
        "move" => {
            let to = extract_kwarg_string(line, "to").unwrap_or_default();
            if to.is_empty() {
                return Err("a move needs a destination path (to:)".to_string());
            }
            let from = extract_string(before_kwarg(line, "to")).unwrap_or_default();
            if from.is_empty() {
                return Err("a move needs a source path".to_string());
            }
            aggregate.moves.push(TranslationMove { from, to });
        }
        "convert" => {
            let to = extract_kwarg_string(line, "to").unwrap_or_default();
            if to.is_empty() {
                return Err("a convert needs a destination path (to:)".to_string());
            }
            let from = extract_string(before_kwarg(line, "to")).unwrap_or_default();
            if from.is_empty() {
                return Err("a convert needs a source path".to_string());
            }
            let values = extract_values_block(line).map(|block| parse_convert_values(&block)).unwrap_or_default();
            if values.is_empty() {
                return Err("a convert needs a values: table".to_string());
            }
            aggregate.converts.push(TranslationConvert { from, to, values });
        }
        "drop" => {
            // `drop :note` (a whole attribute) or `drop "price.currency"`
            // (a dotted value-object member) — try the quoted-path form
            // first, since a bare symbol line has no quote at all.
            let dropped = extract_string(line).or_else(|| extract_symbol(line)).unwrap_or_default();
            if dropped.is_empty() {
                return Err("a drop needs a name".to_string());
            }
            aggregate.drops.push(dropped);
        }
        "retype" => {
            let old = extract_string(before_kwarg(line, "to")).unwrap_or_default();
            if old.is_empty() {
                return Err("a retype needs a source type name".to_string());
            }
            let new = extract_kwarg_string(line, "to").unwrap_or_default();
            if new.is_empty() {
                return Err("a retype needs a destination type name (to:)".to_string());
            }
            aggregate.retypes.push(TranslationRetype { from: old, to: new });
        }
        "compute" => {
            let to = extract_kwarg_string(line, "to").unwrap_or_default();
            if to.is_empty() {
                return Err("a compute needs a destination path (to:)".to_string());
            }
            let from = extract_string(before_kwarg(line, "to")).unwrap_or_default();
            if from.is_empty() {
                return Err("a compute needs a source path".to_string());
            }
            let sql = extract_kwarg_string(line, "sql").unwrap_or_default();
            if sql.is_empty() {
                return Err("a compute needs its sql: expression".to_string());
            }
            aggregate.computes.push(TranslationCompute { from, to, sql });
        }
        "unresolved" => {
            let name = extract_string(before_kwarg(line, "candidates"))
                .or_else(|| extract_symbol(before_kwarg(line, "candidates")))
                .unwrap_or_default();
            if name.is_empty() {
                return Err("an unresolved needs a name".to_string());
            }
            return Err(unresolved_message(&aggregate.name, &name, &unresolved_candidates(line)));
        }
        word => {
            return Err(format!(
                "a translation rule must be rename, move, convert, drop, retype, compute, or unresolved — got '{word}'"
            ));
        }
    }
    Ok(())
}

/// The scaffold writes `unresolved` where it cannot decide; a file
/// carrying one can only boot into this refusal — never a guess.
/// Byte-identical to the Ruby builder's message.
fn unresolved_message(aggregate: &str, name: &str, candidates: &[String]) -> String {
    let rendered: Vec<String> = candidates.iter().map(|candidate| render_path(candidate)).collect();
    if rendered.is_empty() {
        format!(
            "{aggregate}'s translation leaves {} unresolved (no candidate matched — \
             consider drop, or compute on Postgres) — replace unresolved with a real rule before booting.",
            render_path(name)
        )
    } else {
        format!(
            "{aggregate}'s translation leaves {} unresolved (candidates: {}) — \
             replace unresolved with a rename, move, convert, or drop before booting.",
            render_path(name),
            rendered.join(", ")
        )
    }
}

fn unresolved_candidates(line: &str) -> Vec<String> {
    let Some(marker) = line.find("candidates:") else {
        return vec![];
    };
    let rest = &line[marker..];
    let Some(open) = rest.find('[') else {
        return vec![];
    };
    let Some(close) = rest.rfind(']') else {
        return vec![];
    };
    split_top_level_commas(&rest[open + 1..close])
        .into_iter()
        .filter_map(|token| {
            let token = token.trim();
            if token.is_empty() {
                return None;
            }
            extract_string(token).or_else(|| extract_symbol(token)).or(Some(token.to_string()))
        })
        .collect()
}

fn render_path(path: &str) -> String {
    if path.contains('.') {
        format!("{path:?}")
    } else {
        format!(":{path}")
    }
}

fn first_word(line: &str) -> &str {
    line.split([' ', '\t', '(']).next().unwrap_or(line)
}

/// The slice of `line` before `kwarg:` — so a positional extraction
/// (the rule's source symbol or quoted path) can never mistake the
/// keyword argument's value for the missing positional one.
fn before_kwarg<'a>(line: &'a str, kwarg: &str) -> &'a str {
    let marker = format!("{kwarg}:");
    match line.find(&marker) {
        Some(position) => &line[..position],
        None => line,
    }
}

/// A local, typed twin of `hecksagon_helpers::parse_hash_pairs` — that
/// helper returns `(String, String)` for its own callers (plain string
/// config, elsewhere), which would silently flatten a boolean or integer
/// key into text and never match the raw typed value at replay. `convert`
/// needs to know a key was `true` and not the string `"true"`.
fn parse_convert_values(block: &str) -> Vec<(ConvertLiteral, ConvertLiteral)> {
    split_top_level_commas(block)
        .into_iter()
        .filter_map(|pair| {
            let pair = pair.trim();
            pair.find("=>").map(|arrow| (ConvertLiteral::parse(pair[..arrow].trim()), ConvertLiteral::parse(pair[arrow + 2..].trim())))
        })
        .collect()
}

fn extract_values_block(line: &str) -> Option<String> {
    let marker = line.find("values:")?;
    let rest = &line[marker..];
    let start = rest.find('{')? + 1;
    let end = rest.rfind('}')?;
    Some(rest[start..end].to_string())
}

fn ends_with_do(line: &str) -> bool {
    let t = line.trim_end();
    t == "do" || t.ends_with(" do")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_rename_a_move_a_convert_and_a_drop() {
        let source = r#"
Hecks.data_translation "Lineage", from: "1", to: "2" do
  aggregate "Account", was: "Acct" do
    rename :cost, to: :amount
    move "price.cents", to: "price_cents"
    convert "kind.label", to: "kind.label", values: { "biz" => "business", "pers" => "personal" }
    drop :legacy_note
  end
end
"#;
        let translation = parse(source).unwrap();
        assert_eq!(translation.domain, "Lineage");
        assert_eq!(translation.from, "1");
        assert_eq!(translation.to, "2");

        let account = translation.for_aggregate("Account").unwrap();
        assert_eq!(account.was.as_deref(), Some("Acct"));
        assert_eq!(account.renames, vec![("cost".to_string(), "amount".to_string())]);
        assert_eq!(account.moves.len(), 1);
        assert_eq!(account.moves[0].from, "price.cents");
        assert_eq!(account.moves[0].to, "price_cents");
        assert_eq!(account.converts.len(), 1);
        assert_eq!(account.converts[0].from, "kind.label");
        assert_eq!(
            account.converts[0].values,
            vec![
                (ConvertLiteral::Str("biz".to_string()), ConvertLiteral::Str("business".to_string())),
                (ConvertLiteral::Str("pers".to_string()), ConvertLiteral::Str("personal".to_string())),
            ]
        );
        assert_eq!(account.drops, vec!["legacy_note".to_string()]);
        assert!(account.explains("cost"));
        assert!(account.explains("price"));
        assert!(account.explains("kind"));
        assert!(account.explains("legacy_note"));
        assert!(!account.explains("untouched"));
    }

    #[test]
    fn parses_a_dotted_drop_naming_a_value_object_member() {
        let source = r#"
Hecks.data_translation "Lineage", from: "1", to: "2" do
  aggregate "Account" do
    drop "price.currency"
  end
end
"#;
        let translation = parse(source).unwrap();
        let account = translation.for_aggregate("Account").unwrap();
        assert_eq!(account.drops, vec!["price.currency".to_string()]);
    }

    #[test]
    fn parses_a_convert_with_integer_and_boolean_keyed_values() {
        let source = r#"
Hecks.data_translation "Lineage", from: "1", to: "2" do
  aggregate "Account" do
    convert "rank.level", to: "rank.level", values: { 1 => "bronze", 2 => "silver", 3 => "gold" }
    convert "active.flag", to: "status.label", values: { true => "open", false => "closed" }
  end
end
"#;
        let translation = parse(source).unwrap();
        let account = translation.for_aggregate("Account").unwrap();

        assert_eq!(
            account.converts[0].values,
            vec![
                (ConvertLiteral::Int(1), ConvertLiteral::Str("bronze".to_string())),
                (ConvertLiteral::Int(2), ConvertLiteral::Str("silver".to_string())),
                (ConvertLiteral::Int(3), ConvertLiteral::Str("gold".to_string())),
            ]
        );
        assert_eq!(
            account.converts[1].values,
            vec![
                (ConvertLiteral::Bool(true), ConvertLiteral::Str("open".to_string())),
                (ConvertLiteral::Bool(false), ConvertLiteral::Str("closed".to_string())),
            ]
        );
    }

    #[test]
    fn parses_a_retype_and_a_retired_declaration() {
        let source = r#"
Hecks.data_translation "Lineage", from: "1", to: "2" do
  aggregate "Account" do
    retype "Money", to: "Cash"
  end
  retired "Ledger"
end
"#;
        let translation = parse(source).unwrap();
        let account = translation.for_aggregate("Account").unwrap();
        assert_eq!(account.retypes, vec![TranslationRetype { from: "Money".to_string(), to: "Cash".to_string() }]);
        assert_eq!(translation.retired, vec!["Ledger".to_string()]);
    }

    #[test]
    fn parses_a_compute_and_its_from_path_counts_as_explained() {
        let source = r#"
Hecks.data_translation "Lineage", from: "1", to: "2" do
  aggregate "Account" do
    compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100"
  end
end
"#;
        let translation = parse(source).unwrap();
        let account = translation.for_aggregate("Account").unwrap();
        assert_eq!(
            account.computes,
            vec![TranslationCompute {
                from: "price_cents".to_string(),
                to: "price_dollars".to_string(),
                sql: "price_cents::numeric / 100".to_string()
            }]
        );
        assert!(account.explains("price_cents"));
    }

    /// Byte-identical to Ruby's `TranslationBuilder`/`TranslationAggregateBuilder`
    /// `Malformed` messages — the Layer-0 contract. A missing field is a
    /// loud refusal, never a silently absent rule.
    #[test]
    fn refuses_every_required_field_omission_with_ruby_s_exact_wording() {
        let cases: Vec<(&str, &str)> = vec![
            (r#"Hecks.data_translation "", from: "1", to: "2" do"#, "a translation names no domain"),
            (r#"Hecks.data_translation "Lineage", to: "2" do"#, "Lineage's translation says nothing about its origin era (from:)"),
            (r#"Hecks.data_translation "Lineage", from: "1" do"#, "Lineage's translation says nothing about its destination era (to:)"),
        ];
        for (line, wanted) in cases {
            assert_eq!(parse(line).unwrap_err(), wanted, "for {line:?}");
        }

        let rule_cases: Vec<(&str, &str)> = vec![
            ("rename to: :amount", "a rename needs a source name"),
            ("rename :cost", "a rename needs a destination name (to:)"),
            (r#"move "price.cents""#, "a move needs a destination path (to:)"),
            (r#"move to: "price_cents""#, "a move needs a source path"),
            (r#"convert "code""#, "a convert needs a destination path (to:)"),
            (r#"convert to: "code", values: { 1 => "USD" }"#, "a convert needs a source path"),
            (r#"convert "code", to: "code""#, "a convert needs a values: table"),
            (r#"convert "code", to: "code", values: {}"#, "a convert needs a values: table"),
            ("drop", "a drop needs a name"),
            (r#"retype to: "Cash""#, "a retype needs a source type name"),
            (r#"retype "Money""#, "a retype needs a destination type name (to:)"),
            (r#"compute "price_cents""#, "a compute needs a destination path (to:)"),
            (r#"compute to: "price_dollars", sql: "x""#, "a compute needs a source path"),
            (r#"compute "price_cents", to: "price_dollars""#, "a compute needs its sql: expression"),
        ];
        for (rule, wanted) in rule_cases {
            let source = format!(
                "Hecks.data_translation \"Lineage\", from: \"1\", to: \"2\" do\n  aggregate \"Account\" do\n    {rule}\n  end\nend\n"
            );
            assert_eq!(parse(&source).unwrap_err(), wanted, "for {rule:?}");
        }

        let source = "Hecks.data_translation \"Lineage\", from: \"1\", to: \"2\" do\n  aggregate \"\" do\n  end\nend\n";
        assert_eq!(parse(source).unwrap_err(), "an aggregate translation needs a name");

        let source = "Hecks.data_translation \"Lineage\", from: \"1\", to: \"2\" do\n  retired\nend\n";
        assert_eq!(parse(source).unwrap_err(), "a retired needs an aggregate name");
    }

    #[test]
    fn refuses_an_unknown_construct_rather_than_skipping_it() {
        let source = "Hecks.data_translation \"Lineage\", from: \"1\", to: \"2\" do\n  aggregate \"Account\" do\n    renmae :cost, to: :amount\n  end\nend\n";
        assert_eq!(
            parse(source).unwrap_err(),
            "a translation rule must be rename, move, convert, drop, retype, compute, or unresolved — got 'renmae'"
        );

        let source = "Hecks.data_translation \"Lineage\", from: \"1\", to: \"2\" do\n  banana \"Account\"\nend\n";
        assert_eq!(
            parse(source).unwrap_err(),
            "a translation does not understand 'banana' — it declares aggregate blocks and retired aggregates"
        );
    }

    #[test]
    fn an_unresolved_placeholder_refuses_at_parse_never_boots_into_a_guess() {
        let source = "Hecks.data_translation \"Lineage\", from: \"1\", to: \"2\" do\n  aggregate \"Account\" do\n    unresolved :cost, candidates: [:amount, :price_cents]\n  end\nend\n";
        assert_eq!(
            parse(source).unwrap_err(),
            "Account's translation leaves :cost unresolved (candidates: :amount, :price_cents) — \
             replace unresolved with a rename, move, convert, or drop before booting."
        );

        let source = "Hecks.data_translation \"Lineage\", from: \"1\", to: \"2\" do\n  aggregate \"Account\" do\n    unresolved \"price.currency\", candidates: []\n  end\nend\n";
        assert_eq!(
            parse(source).unwrap_err(),
            "Account's translation leaves \"price.currency\" unresolved (no candidate matched — \
             consider drop, or compute on Postgres) — replace unresolved with a real rule before booting."
        );
    }
}
