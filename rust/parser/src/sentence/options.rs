//! The options an attribute carries after its type: `optional`, `default 0`, `matching "…"`,
//! `admits Name`. They are read from the comma-separated tail of an attribute or value sentence and
//! written back in that order.

use super::{column, Matched, Parser};
use crate::diag::ParseResult;
use crate::ir;
use crate::ruby_value::{self, Value};

/// What a tail of options said.
#[derive(Default)]
pub(super) struct Options {
    pub optional: bool,
    pub default: Option<Value>,
    pub pattern: Option<String>,
    pub admits: Option<String>,
}

impl Options {
    /// Writes the options onto `attribute`.
    pub(super) fn onto(self, attribute: &mut ir::Attribute) {
        attribute.optional |= self.optional;
        attribute.default = self.default.or_else(|| attribute.default.take());
        attribute.pattern = self.pattern.or_else(|| attribute.pattern.take());
        attribute.admits = self.admits.or_else(|| attribute.admits.take());
    }
}

impl Parser<'_> {
    /// Reads the `options` slot of a matched sentence.
    pub(super) fn attribute_options(&self, m: &Matched) -> ParseResult<Options> {
        let text = m.text_of("options");
        let base = m.col_of("options");
        let mut options = Options::default();
        for item in ruby_value::split_items(&text) {
            let item = item.trim();
            let col = column(base, &text, text.find(item).unwrap_or(0));
            let (word, rest) = item.split_once(' ').map_or((item, ""), |(word, rest)| (word, rest.trim()));
            match word.to_lowercase().as_str() {
                "optional" if rest.is_empty() => options.optional = true,
                "default" if !rest.is_empty() => options.default = Some(self.default_value(m, col, rest)?),
                "matching" => options.pattern = Some(self.pattern_text(m, col, rest)?),
                "admits" if !rest.is_empty() => options.admits = Some(rest.to_string()),
                _ => {
                    return Err(self
                        .error(m.line, col, format!("'{item}' is not an option an attribute takes"))
                        .with_expected(vec![
                            "optional".to_string(),
                            "default <value>".to_string(),
                            "matching \"<pattern>\"".to_string(),
                            "admits <set>".to_string(),
                        ]));
                }
            }
        }
        Ok(options)
    }

    fn default_value(&self, m: &Matched, col: usize, text: &str) -> ParseResult<Value> {
        match ruby_value::read(text) {
            Value::Bare(_) => Err(self.error(
                m.line,
                col,
                format!("a default is a number, quoted text, true, false, nothing or a {{value: …}}; '{text}' is none of those"),
            )),
            value => Ok(value),
        }
    }

    /// The pattern between the quotes of `matching "…"`, kept exactly as written.
    fn pattern_text(&self, m: &Matched, col: usize, text: &str) -> ParseResult<String> {
        let source = text
            .strip_prefix('"')
            .and_then(|rest| rest.strip_suffix('"'))
            .ok_or_else(|| self.error(m.line, col, "matching takes a pattern in quotes, like `matching \"[a-z]+\"`"))?;
        if let Some(rejection) = crate::build::pattern_subset::validate(source) {
            return Err(self.error(
                m.line,
                col,
                format!("the pattern uses a {} — {}", rejection.construct, rejection.reason),
            ));
        }
        Ok(source.to_string())
    }
}

impl Parser<'_> {
    /// The cells of a `Member kind "hero", requires "heading"` line: each a name and a literal.
    pub(super) fn member_cells(&self, m: &Matched) -> ParseResult<Vec<(String, Value)>> {
        let text = m.text_of("pairs");
        let base = m.col_of("pairs");
        let mut cells = Vec::new();
        for item in ruby_value::split_items(&text) {
            let item = item.trim();
            let col = column(base, &text, text.find(item).unwrap_or(0));
            let (name, value) = item.split_once(' ').map_or((item, ""), |(name, value)| (name, value.trim()));
            let parsed = ruby_value::read(value);
            if value.is_empty() || matches!(parsed, Value::Bare(_)) {
                return Err(self.error(m.line, col, format!("'{item}' needs a name and a value, like `kind \"hero\"`")));
            }
            cells.push((name.to_string(), parsed));
        }
        Ok(cells)
    }
}

/// The tail `, optional, default 0, matching "…"` that says `attribute`'s options, or nothing when
/// it has none. Refuses what the options cannot say.
pub(super) fn said(attribute: &ir::Attribute) -> Result<String, String> {
    let mut items: Vec<String> = Vec::new();
    if attribute.optional {
        items.push("optional".to_string());
    }
    if let Some(default) = &attribute.default {
        items.push(format!("default {}", ruby_value::render(default)));
    }
    if let Some(pattern) = &attribute.pattern {
        if pattern.contains('"') {
            return Err(format!("the sentence form cannot quote a pattern holding a quote: {pattern}"));
        }
        items.push(format!("matching \"{pattern}\""));
    }
    if let Some(admits) = &attribute.admits {
        items.push(format!("admits {admits}"));
    }
    Ok(items.iter().fold(String::new(), |tail, item| format!("{tail}, {item}")))
}
