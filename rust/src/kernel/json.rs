//! The JSON value the WASM/CLI boundary speaks, with a hand-written parser and writer.
//! Kept separate from `expr::Value`; zero Cargo dependencies (ADR 0012).

use super::Refusal;

#[derive(Debug, Clone)]
pub enum Json {
    Object(Vec<(String, Json)>),
    Array(Vec<Json>),
    Str(String),
    /// The second field is the exact source text (BUG#147) — set only when the literal's
    /// magnitude means the `f64` approximation would not reproduce it, e.g. an integer past
    /// `f64`'s ~53-bit exact range. `None` for anything the `f64` already renders exactly,
    /// which is every ordinary number and everything built in memory (`Json::float`, an
    /// arithmetic result, a codegen literal). Never set for `Float`: Ruby's own `Float` is the
    /// same IEEE 754 binary64 as Rust's, so there is no cross-language precision gap to close.
    Num(f64, Option<String>),
    /// A declared-Float value: always written with a decimal point (`10.0`), unlike `Num`.
    Float(f64),
    Bool(bool),
    Null,
}

impl PartialEq for Json {
    /// The source text (`Num`'s second field) is provenance, not part of the value: two `Num`s
    /// compare equal by magnitude, exactly as they did before that field existed. When both
    /// sides carry exact text, comparing the text avoids the `f64` rounding that put them there
    /// in the first place; otherwise the numeric comparison is unchanged.
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Json::Object(a), Json::Object(b)) => a == b,
            (Json::Array(a), Json::Array(b)) => a == b,
            (Json::Str(a), Json::Str(b)) => a == b,
            (Json::Num(_, Some(araw)), Json::Num(_, Some(braw))) => araw == braw,
            (Json::Num(a, _), Json::Num(b, _)) => a == b,
            (Json::Float(a), Json::Float(b)) => a == b,
            (Json::Bool(a), Json::Bool(b)) => a == b,
            (Json::Null, Json::Null) => true,
            _ => false,
        }
    }
}

/// A `Json` as a `Fielded`, for evaluating a policy's `where { ... }` against an event payload.
impl super::Fielded for Json {
    fn field(&self, name: &str) -> Option<super::Field<'_>> {
        use super::{Field, Value};
        let Json::Object(pairs) = self else { return None };
        let (_, found) = pairs.iter().find(|(k, _)| k == name)?;
        Some(match found {
            Json::Object(_) => Field::Nested(found),
            Json::Array(items) => Field::Value(Value::List(items.len())),
            Json::Str(s) => Field::Value(Value::Str(s.clone())),
            Json::Num(n, raw) => match exact_i64(*n, raw) {
                Some(i) => Field::Value(Value::Int(i)),
                None => Field::Value(Value::Float(*n)),
            },
            // Float already carries the Integer-or-Float answer that `Num` must guess.
            Json::Float(n) => Field::Value(Value::Float(*n)),
            Json::Bool(b) => Field::Value(Value::Bool(*b)),
            Json::Null => Field::Value(Value::Nil),
        })
    }

    fn items(&self, name: &str) -> Option<Vec<super::Field<'_>>> {
        use super::{Field, Value};
        let Json::Object(pairs) = self else { return None };
        let (_, found) = pairs.iter().find(|(k, _)| k == name)?;
        let Json::Array(items) = found else { return None };
        Some(
            items
                .iter()
                .map(|item| match item {
                    Json::Object(_) => Field::Nested(item),
                    Json::Array(inner) => Field::Value(Value::List(inner.len())),
                    Json::Str(s) => Field::Value(Value::Str(s.clone())),
                    Json::Num(n, raw) => match exact_i64(*n, raw) {
                        Some(i) => Field::Value(Value::Int(i)),
                        None => Field::Value(Value::Float(*n)),
                    },
                    Json::Float(n) => Field::Value(Value::Float(*n)),
                    Json::Bool(b) => Field::Value(Value::Bool(*b)),
                    Json::Null => Field::Value(Value::Nil),
                })
                .collect(),
        )
    }

    // A `Json` has no declaration to consult, so one key of any name is the whole shape test.
    fn as_scalar(&self) -> Option<super::Value> {
        let Json::Object(pairs) = self else { return None };
        if pairs.len() != 1 {
            return None;
        }
        match self.field(&pairs[0].0) {
            Some(super::Field::Value(v)) => Some(v),
            _ => None,
        }
    }
}

impl Json {
    pub fn obj(fields: Vec<(&str, Json)>) -> Json {
        Json::Object(fields.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    pub fn str(s: impl Into<String>) -> Json {
        Json::Str(s.into())
    }

    /// The raw text is always the exact `i64`, not derived from the `f64` cast: `i as f64`
    /// itself rounds near the `i64` boundaries, which would otherwise reintroduce BUG#147's
    /// class of loss for an in-range value built straight from a Rust integer.
    pub fn int(i: i64) -> Json {
        Json::Num(i as f64, Some(i.to_string()))
    }

    pub fn float(f: f64) -> Json {
        Json::Float(f)
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// A tolerant dotted-path walk: a non-object reached mid-path is the answer.
    ///
    /// A `Reference<X>` argument arrives as a bare string where a wrapped value is expected.
    pub fn dig(&self, path: &str) -> Option<&Json> {
        let mut current = self;
        for segment in path.split('.') {
            match current {
                Json::Object(_) => current = current.get(segment)?,
                _ => return Some(current),
            }
        }
        Some(current)
    }

    /// Ruby's `#inspect` for quoting an offered value in a refusal message.
    ///
    /// An Array prints as `[5, 4]` (comma and space), not the compact wire form;
    /// an Object stays compact JSON.
    pub fn inspect(&self) -> String {
        match self {
            Json::Str(s) => {
                let mut out = String::new();
                write_escaped_string(s, &mut out);
                out
            }
            Json::Null => "nil".to_string(),
            Json::Array(items) => {
                let mut out = String::from("[");
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    out.push_str(&item.inspect());
                }
                out.push(']');
                out
            }
            // Numbers and bools already print like Ruby; an Object stays compact JSON.
            _ => self.to_json_string(),
        }
    }

    /// Ruby's `#to_s` for a raw offered value, as a closed-set membership check compares it.
    ///
    /// Arrays, Objects and fractions fall back to compact JSON; they never match a member.
    pub fn ruby_to_s(&self) -> String {
        match self {
            Json::Str(s) => s.clone(),
            Json::Null => String::new(),
            Json::Bool(b) => b.to_string(),
            Json::Num(n, _) if n.fract() == 0.0 && n.abs() < 1e15 => format!("{}", *n as i64),
            _ => self.to_json_string(),
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    /// `None` for a fractional number or one outside `i64`, never a truncation or saturation.
    ///
    /// Reads the exact source text first (BUG#147): a whole number between `f64`'s ~53-bit exact
    /// range and `i64::MAX` round-trips through `f64` inexactly even though it fits in `i64`.
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Num(n, raw) => exact_i64(*n, raw),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n, _) | Json::Float(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    /// Wraps a bare scalar as a one-field object under `field_name`; an object passes through.
    ///
    /// Mirrors `Value.for_attribute`'s bare-value admission for a single-attribute value object.
    pub fn coerce_single_field(&self, field_name: &str) -> Json {
        match self {
            Json::Object(_) => self.clone(),
            other => Json::obj(vec![(field_name, other.clone())]),
        }
    }

    /// How a refusal quotes an offered value: compact JSON for an Array or Object, else `inspect`.
    pub fn describe(&self) -> String {
        match self {
            Json::Array(_) | Json::Object(_) => self.to_json_string(),
            other => other.inspect(),
        }
    }

    /// Refuses `TypeMismatch` when a multi-field value object is offered as a non-object.
    ///
    /// Runs at the `from_json` call site, since only the caller knows `name`.
    pub fn expect_value_object_shape(&self, name: &str, type_name: &str) -> Result<&Json, Refusal> {
        match self {
            Json::Object(_) => Ok(self),
            other => Err(Refusal::TypeMismatch(
                super::refusal_wording::TypeMismatchValueObjectShapeArgs {
                    name,
                    r#type: type_name,
                    offered: &other.describe(),
                }
                .render_args(),
            )),
        }
    }

    /// A required-field lookup that refuses `TypeMismatch` when the key is missing.
    pub fn require(&self, key: &str, struct_name: &str) -> Result<&Json, Refusal> {
        self.get(key)
            .ok_or_else(|| Refusal::TypeMismatch(format!("{struct_name}.{key}: missing from JSON args")))
    }

    /// The keys of a command's args that are not in `known`, sorted.
    ///
    /// Sorted because refusal wording is pinned by corpus fixtures and cannot depend on key order.
    pub fn unknown_keys(&self, known: &[&str]) -> Vec<String> {
        match self {
            Json::Object(fields) => {
                let mut unknown: Vec<String> = fields.iter().filter(|(k, _)| !known.contains(&k.as_str())).map(|(k, _)| k.clone()).collect();
                unknown.sort();
                unknown
            }
            _ => Vec::new(),
        }
    }

    /// Merges `patch` over `base`: `patch` wins per top-level key, other `base` keys are kept.
    ///
    /// The typed args carry declared defaults that the raw `args_json` lacks, while the raw
    /// args keep identity/reference arguments no attribute names. Non-objects return `base`.
    pub fn overlay(base: &Json, patch: &Json) -> Json {
        let (Json::Object(base_fields), Json::Object(patch_fields)) = (base, patch) else {
            return base.clone();
        };
        let mut merged = base_fields.clone();
        for (key, value) in patch_fields {
            match merged.iter_mut().find(|(k, _)| k == key) {
                Some(entry) => entry.1 = value.clone(),
                None => merged.push((key.clone(), value.clone())),
            }
        }
        Json::Object(merged)
    }

    /// Adds each target key of `pairs` holding its source key's value, keeping existing args.
    ///
    /// A source key that is absent adds nothing. Non-objects pass through.
    pub fn with_aliases(&self, pairs: &[(&str, &str)]) -> Json {
        let Json::Object(fields) = self else {
            return self.clone();
        };
        let mut merged = fields.clone();
        for (target_key, source_key) in pairs {
            let Some(value) = fields.iter().find(|(k, _)| k == source_key).map(|(_, v)| v.clone()) else { continue };
            match merged.iter_mut().find(|(k, _)| k == target_key) {
                Some(entry) => entry.1 = value,
                None => merged.push((target_key.to_string(), value)),
            }
        }
        Json::Object(merged)
    }

    /// Stringifies a scalar leaf as an identity component.
    ///
    /// An empty string refuses, as `Runtime::Identity.of` treats a blank part as absent.
    /// A number past `i64` prints its exact source digits (BUG#147), never a clamped or
    /// `f64`-rounded value: an identity component is routing data, never arithmetic, and Ruby
    /// carries it at its full, arbitrary-precision magnitude.
    pub fn to_id_component(&self) -> Result<String, Refusal> {
        match self {
            Json::Str(s) if s.is_empty() => {
                Err(Refusal::TypeMismatch("identity component must not be empty".to_string()))
            }
            Json::Str(s) => Ok(s.clone()),
            Json::Num(n, raw) => match exact_i64(*n, raw) {
                // In range: a plain integer, as Ruby prints it.
                Some(i) => Ok(i.to_string()),
                // Out of range or fractional: the exact source text when there is one (a
                // Bignum past i64), else the float's own digits; `as i64` would saturate.
                None => Ok(raw.clone().unwrap_or_else(|| n.to_string())),
            },
            Json::Bool(b) => Ok(b.to_string()),
            other => Err(Refusal::TypeMismatch(format!("cannot use {other:?} as an identity component"))),
        }
    }

    /// Like `to_id_component`, but a blank string is accepted, for entity-element addressing.
    ///
    /// A present-but-blank key is an ordinary non-matching value there; non-scalars still refuse.
    pub fn to_id_component_lenient(&self) -> Result<String, Refusal> {
        match self {
            Json::Str(s) => Ok(s.clone()),
            other => other.to_id_component(),
        }
    }

    pub fn parse(input: &str) -> Result<Json, String> {
        let mut parser = Parser { chars: input.chars().peekable() };
        let value = parser.parse_value()?;
        parser.skip_ws();
        Ok(value)
    }

    pub fn to_json_string(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Json::Object(fields) => {
                out.push('{');
                for (i, (k, v)) in fields.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_escaped_string(k, out);
                    out.push(':');
                    v.write(out);
                }
                out.push('}');
            }
            Json::Array(items) => {
                out.push('[');
                for (i, v) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    v.write(out);
                }
                out.push(']');
            }
            Json::Str(s) => write_escaped_string(s, out),
            // The exact source text wins when there is one (BUG#147): re-deriving digits from
            // `n` would re-round a value the `f64` approximation already lost precision on.
            Json::Num(_, Some(raw)) => out.push_str(raw),
            Json::Num(n, None) => out.push_str(&canonical_integer_digits(*n)),
            // Always a decimal point (`10.0`), as Ruby's Float#to_json; `Num` must not grow one.
            Json::Float(n) => {
                let rendered = n.to_string();
                out.push_str(&rendered);
                if !rendered.contains('.') && !rendered.contains('e') && !rendered.contains('E') {
                    out.push_str(".0");
                }
            }
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Null => out.push_str("null"),
        }
    }
}

/// Whether `n` is a whole number within `i64`; `as i64` would silently saturate outside it.
///
/// `i64::MAX as f64` rounds up to 2^63, so the strict `<` excludes exactly the saturating value.
fn integral_i64(n: f64) -> Option<i64> {
    if n.fract() == 0.0 && n >= i64::MIN as f64 && n < i64::MAX as f64 {
        Some(n as i64)
    } else {
        None
    }
}

/// A `Num`'s exact `i64` value, when it has one (BUG#147).
///
/// Prefers the source text: `f64` only represents every integer exactly up to 2^53, so a whole
/// number with more digits than that — while still well within `i64` — can already round to the
/// wrong `i64` via `integral_i64`'s `f64` path alone. Parsing the original digits sidesteps that
/// gap; `raw` is `None` for anything short enough that the gap never opens, so this is the same
/// answer `integral_i64` already gave for every value the old, one-field `Num` could represent.
fn exact_i64(n: f64, raw: &Option<String>) -> Option<i64> {
    raw.as_deref().and_then(|r| r.parse::<i64>().ok()).or_else(|| integral_i64(n))
}

/// The digits `write` prints for a `Num` with no exact source text: whichever of the two
/// renderings `write`/`to_id_component` have always used is faithful to `n` itself.
///
/// Shared with `parse_number`, which compares a literal's digits against this same rendering to
/// decide whether the literal needs to keep its source text at all.
fn canonical_integer_digits(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 {
        (n as i64).to_string()
    } else {
        n.to_string()
    }
}

#[cfg(test)]
mod integral_i64_tests {
    use super::*;

    #[test]
    fn accepts_ordinary_whole_numbers() {
        assert_eq!(integral_i64(0.0), Some(0));
        assert_eq!(integral_i64(42.0), Some(42));
        assert_eq!(integral_i64(-42.0), Some(-42));
    }

    #[test]
    fn rejects_fractional_numbers() {
        assert_eq!(integral_i64(25.5), None);
    }

    #[test]
    fn accepts_i64_boundaries() {
        assert_eq!(integral_i64(i64::MIN as f64), Some(i64::MIN));
        // Largest f64 below 2^63; `i64::MAX` itself rounds up to 2^63 in f64.
        let largest_safe = 9223372036854774784.0_f64;
        assert_eq!(integral_i64(largest_safe), Some(largest_safe as i64));
    }

    #[test]
    fn accepts_i64_saturation_boundary() {
        // `as i64` would saturate on either of these.
        assert_eq!(integral_i64(2f64.powi(63)), None, "2^63 must not saturate to i64::MAX");
        // Near 2^63 a small nudge rounds back to the same float, so use 2^64.
        assert_eq!(integral_i64(-(2f64.powi(64))), None, "well below i64::MIN must not saturate to i64::MIN");
    }

    #[test]
    fn as_i64_refuses_out_of_range_where_the_old_cast_would_have_saturated() {
        // Pins the regression: a huge number must not saturate to `Some(i64::MAX)`.
        let huge = Json::Num(1e30, None);
        assert_eq!(huge.as_i64(), None);
    }

    #[test]
    fn to_id_component_reflects_true_magnitude_instead_of_a_clamped_one() {
        let huge = Json::Num(1e30, None);
        let id = huge.to_id_component().expect("numbers are always usable as an id component");
        assert_ne!(id, i64::MAX.to_string(), "must not silently clamp to i64::MAX");
        assert!(id.starts_with('1'), "should reflect the real magnitude, got {id:?}");
    }

    #[test]
    fn parse_preserves_a_huge_integers_exact_digits_past_f64_precision() {
        // BUG#147: 2^100 (2**100, the fuzzer's own INTEGER_EDGE_CASES bignum), and the
        // signed 31-digit repro from Roster::Roster.AddSeat's routing_key mutation.
        for literal in ["-1267650600228229401496703205376", "1267650600228229401496703205376"] {
            let parsed = Json::parse(literal).expect("a bare JSON integer parses");
            assert_eq!(parsed.to_json_string(), literal, "re-emitted JSON must not lose a single digit");
            assert_eq!(
                parsed.to_id_component().unwrap(),
                literal,
                "an identity component must carry the caller's exact digits, not a rounded f64"
            );
            // Genuinely out of i64's range: still correctly refused, not silently truncated.
            assert_eq!(parsed.as_i64(), None);
        }
    }

    #[test]
    fn parse_preserves_a_whole_number_between_f64s_exact_range_and_i64_max() {
        // 2^60: fits comfortably in `i64`, but has more digits than `f64` can hold exactly, so
        // the naive `s.parse::<f64>()` path alone already rounds it to the wrong integer.
        let literal = "1152921504606846977"; // 2^60 + 1
        let parsed = Json::parse(literal).expect("a bare JSON integer parses");
        assert_eq!(parsed.as_i64(), Some(1_152_921_504_606_846_977));
        assert_eq!(parsed.to_json_string(), literal);
        assert_eq!(parsed.to_id_component().unwrap(), literal);
    }

    #[test]
    fn parse_leaves_an_ordinary_integer_undisturbed() {
        // No source text is retained when the f64 path was already exact — same value either way.
        let parsed = Json::parse("42").unwrap();
        assert_eq!(parsed, Json::Num(42.0, None));
        assert_eq!(parsed.to_json_string(), "42");
    }

    #[test]
    fn a_bignum_and_an_ordinary_number_are_still_comparable_and_never_falsely_equal() {
        let huge = Json::parse("1267650600228229401496703205376").unwrap();
        let other_huge = Json::parse("1267650600228229401496703205377").unwrap();
        assert_ne!(huge, other_huge, "different bignums must not collide via f64 rounding");
        assert_eq!(huge, Json::parse("1267650600228229401496703205376").unwrap());
        assert_ne!(huge, Json::Num(5.0, None));
    }

    #[test]
    fn to_id_component_refuses_an_empty_string() {
        // Ruby treats a blank identity part as absent; a blank id must not be accepted.
        let blank = Json::Str(String::new());
        assert!(blank.to_id_component().is_err(), "an empty string must not be usable as an identity component");
    }

    #[test]
    fn to_id_component_still_accepts_a_real_string() {
        let real = Json::Str("acct-1".to_string());
        assert_eq!(real.to_id_component().unwrap(), "acct-1");
    }

    #[test]
    fn to_id_component_lenient_accepts_an_empty_string() {
        // A blank key is truthy in Ruby and flows on as a non-matching value.
        let blank = Json::Str(String::new());
        assert_eq!(blank.to_id_component_lenient().unwrap(), "", "a present, blank string must be a valid (non-matching) component");
    }

    #[test]
    fn to_id_component_lenient_still_refuses_a_non_scalar() {
        // Only the blank-string case differs from `to_id_component`.
        let list = Json::Array(vec![]);
        assert!(list.to_id_component_lenient().is_err(), "a non-scalar must still refuse, same as to_id_component");
    }
}

#[cfg(test)]
mod value_object_shape_tests {
    use super::*;

    fn refusal_text(json: &Json) -> String {
        match json.expect_value_object_shape("name", "PersonName") {
            Err(Refusal::TypeMismatch(text)) => text,
            other => panic!("expected a TypeMismatch refusal, got {other:?}"),
        }
    }

    #[test]
    fn an_object_passes_through_untouched() {
        let object = Json::obj(vec![("given", Json::Str("Ada".into()))]);
        assert!(object.expect_value_object_shape("name", "PersonName").is_ok());
    }

    #[test]
    fn a_scalar_is_refused_in_rubys_wording() {
        assert_eq!(
            refusal_text(&Json::Str("Ada".into())),
            "name is a PersonName — pass its fields as an object, not \"Ada\""
        );
        assert_eq!(refusal_text(&Json::Num(7.0, None)), "name is a PersonName — pass its fields as an object, not 7");
    }

    #[test]
    fn an_array_is_described_as_compact_json() {
        let list = Json::Array(vec![Json::Str("Ada".into()), Json::Str("Lovelace".into())]);
        assert_eq!(
            refusal_text(&list),
            "name is a PersonName — pass its fields as an object, not [\"Ada\",\"Lovelace\"]"
        );
    }
}

fn write_escaped_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

// Recursive descent over chars; the input is a valid `&str`, so no UTF-8 byte handling is needed.
struct Parser<'a> {
    chars: std::iter::Peekable<std::str::Chars<'a>>,
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while matches!(self.chars.peek(), Some(c) if c.is_whitespace()) {
            self.chars.next();
        }
    }

    fn expect(&mut self, ch: char) -> Result<(), String> {
        match self.chars.next() {
            Some(c) if c == ch => Ok(()),
            other => Err(format!("expected {ch:?}, got {other:?}")),
        }
    }

    fn consume_literal(&mut self, lit: &str) -> bool {
        let save = self.chars.clone();
        for expected in lit.chars() {
            if self.chars.next() != Some(expected) {
                self.chars = save;
                return false;
            }
        }
        true
    }

    fn parse_value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.chars.peek() {
            Some('{') => self.parse_object(),
            Some('[') => self.parse_array(),
            Some('"') => self.parse_string().map(Json::Str),
            Some('t') | Some('f') => self.parse_bool(),
            Some('n') => self.parse_null(),
            Some(c) if *c == '-' || c.is_ascii_digit() => self.parse_number(),
            other => Err(format!("unexpected {other:?} in JSON")),
        }
    }

    fn parse_object(&mut self) -> Result<Json, String> {
        self.expect('{')?;
        let mut fields = Vec::new();
        self.skip_ws();
        if self.chars.peek() == Some(&'}') {
            self.chars.next();
            return Ok(Json::Object(fields));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            self.expect(':')?;
            let value = self.parse_value()?;
            fields.push((key, value));
            self.skip_ws();
            match self.chars.next() {
                Some(',') => continue,
                Some('}') => break,
                other => return Err(format!("expected ',' or '}}' in object, got {other:?}")),
            }
        }
        Ok(Json::Object(fields))
    }

    fn parse_array(&mut self) -> Result<Json, String> {
        self.expect('[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.chars.peek() == Some(&']') {
            self.chars.next();
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.chars.next() {
                Some(',') => continue,
                Some(']') => break,
                other => return Err(format!("expected ',' or ']' in array, got {other:?}")),
            }
        }
        Ok(Json::Array(items))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            match self.chars.next() {
                Some('"') => break,
                Some('\\') => match self.chars.next() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('/') => out.push('/'),
                    Some('n') => out.push('\n'),
                    Some('t') => out.push('\t'),
                    Some('r') => out.push('\r'),
                    Some('b') => out.push('\u{8}'),
                    Some('f') => out.push('\u{c}'),
                    Some('u') => {
                        let hex: String = (0..4).map(|_| self.chars.next().unwrap_or('0')).collect();
                        let code = u32::from_str_radix(&hex, 16).map_err(|_| format!("bad \\u escape {hex:?}"))?;
                        out.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
                    }
                    other => return Err(format!("bad escape sequence \\{other:?}")),
                },
                Some(c) => out.push(c),
                None => return Err("unterminated string".to_string()),
            }
        }
        Ok(out)
    }

    fn parse_bool(&mut self) -> Result<Json, String> {
        if self.consume_literal("true") {
            Ok(Json::Bool(true))
        } else if self.consume_literal("false") {
            Ok(Json::Bool(false))
        } else {
            Err("expected true/false".to_string())
        }
    }

    fn parse_null(&mut self) -> Result<Json, String> {
        if self.consume_literal("null") {
            Ok(Json::Null)
        } else {
            Err("expected null".to_string())
        }
    }

    fn parse_number(&mut self) -> Result<Json, String> {
        let mut s = String::new();
        if self.chars.peek() == Some(&'-') {
            s.push(self.chars.next().unwrap());
        }
        while matches!(self.chars.peek(), Some(c) if c.is_ascii_digit()) {
            s.push(self.chars.next().unwrap());
        }
        if self.chars.peek() == Some(&'.') {
            s.push(self.chars.next().unwrap());
            while matches!(self.chars.peek(), Some(c) if c.is_ascii_digit()) {
                s.push(self.chars.next().unwrap());
            }
        }
        if matches!(self.chars.peek(), Some('e') | Some('E')) {
            s.push(self.chars.next().unwrap());
            if matches!(self.chars.peek(), Some('+') | Some('-')) {
                s.push(self.chars.next().unwrap());
            }
            while matches!(self.chars.peek(), Some(c) if c.is_ascii_digit()) {
                s.push(self.chars.next().unwrap());
            }
        }
        let value: f64 = s.parse().map_err(|e| format!("bad number {s:?}: {e}"))?;
        // A plain integer literal keeps its exact source digits (BUG#147) whenever `write`'s own
        // rendering of the parsed `f64` would not reproduce them — i.e. whenever the round trip
        // through `f64` has already lost precision, whether or not the value still fits `i64`.
        // A literal with a `.`/exponent is a genuine `Float`, and Ruby's `Float` is the same
        // `f64` Rust's is, so there is nothing to preserve there.
        let is_plain_integer = !s.contains('.') && !s.contains(['e', 'E']);
        let raw = if is_plain_integer && canonical_integer_digits(value) != s { Some(s) } else { None };
        Ok(Json::Num(value, raw))
    }
}
