// HAND-WRITTEN, ONCE, GENERIC — the wire format the WASM/CLI boundary
// speaks. Zero Cargo dependencies, same style as the rest of this kernel:
// expr.rs's `Value` is the domain-EXPRESSION runtime value (Int/Float/Str/
// Bool/List/Nil, no Object/Array); this `Json` is a separate, general JSON
// value every generated `to_json`/`from_json` (rust/project/json_codec.rb)
// and `dispatch_by_name`'s stdin/stdout CLI contract (kernel/cli.rs) speak.
// Reused rather than merged with `expr::Value` on purpose — an `Expr`
// literal never needs Object/Array, and a `Json` never needs to be
// `interpret()`-walked, so collapsing them would blur two different jobs.
//
// docs/implemented/decisions/0012-wasm-via-wasi-stdio.md: chosen over pulling in
// `serde`/`serde_json` to keep this crate at zero Cargo dependencies,
// the same constraint `rust/src/kernel/{expr,dispatch}.rs` already hold
// themselves to.

use super::Refusal;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Object(Vec<(String, Json)>),
    Array(Vec<Json>),
    Str(String),
    Num(f64),
    /// A declared-Float value, distinct from `Num` ONLY in how it
    /// SERIALISES: `Num` is `f64` used for both Integer- and Float-typed
    /// attributes alike, and its own `write` renders a whole-number value
    /// WITHOUT a decimal point (correct for an Integer attribute that
    /// happens through). `Float` renders WITH one always, matching Ruby's
    /// own `Float#to_json` (`10.0`, never bare `10`) for a Float-typed
    /// attribute whose value happens to be whole. Every other operation
    /// (comparison, ordering, `as_f64`, expression-evaluator field
    /// access) treats the two identically — this variant exists to carry
    /// one bit of lost type provenance through to JSON text, nothing more.
    Float(f64),
    Bool(bool),
    Null,
}

/// A `Json` value AS a `Fielded` — what a policy's own `where { … }`
/// evaluates against: `Evaluator.call(policy.where, {}, event.payload)`
/// (`PolicyInterpreter#where_holds?`, read directly), the payload being a
/// plain Hash there. An object answers its keys, an array its length (and
/// its elements through `items`), a scalar itself; `as_scalar` is
/// `Resolver#unwrap_scalar` — an object with the sole key `value` reads
/// as that value.
impl super::Fielded for Json {
    fn field(&self, name: &str) -> Option<super::Field<'_>> {
        use super::{Field, Value};
        let Json::Object(pairs) = self else { return None };
        let (_, found) = pairs.iter().find(|(k, _)| k == name)?;
        Some(match found {
            Json::Object(_) => Field::Nested(found),
            Json::Array(items) => Field::Value(Value::List(items.len())),
            Json::Str(s) => Field::Value(Value::Str(s.clone())),
            Json::Num(n) => match integral_i64(*n) {
                Some(i) => Field::Value(Value::Int(i)),
                None => Field::Value(Value::Float(*n)),
            },
            // A declared-Float value's field access is ALWAYS Value::Float
            // -- unlike Num, whose Integer-or-Float split is a guess off
            // `integral_i64`, Float already carries the answer.
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
                    Json::Num(n) => match integral_i64(*n) {
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

    fn as_scalar(&self) -> Option<super::Value> {
        let Json::Object(pairs) = self else { return None };
        if pairs.len() != 1 || pairs[0].0 != "value" {
            return None;
        }
        match self.field("value") {
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

    pub fn int(i: i64) -> Json {
        Json::Num(i as f64)
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

    /// A tolerant dotted-path walk — `extract_id`/a process manager's
    /// `correlates_by` both want "the scalar this path names," and a
    /// single-field value object's own wrapped shape (`{"value": "x"}`)
    /// isn't the only way that scalar arrives: a `Reference<X>` argument
    /// (Transfer's own `source`/`destination`, forwarded verbatim by a
    /// process manager's `with:` into a `number:` slot Account's own
    /// `identified_by` expects wrapped) is a BARE string, the same
    /// coercion Ruby's `Value.for_attribute` performs implicitly for a
    /// single-field VO. If the walk still has segments left but the
    /// current value ISN'T an object to walk further into, the value
    /// found so far IS the answer, not a dead end.
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

    /// Ruby's own `#inspect`, close enough for what a refusal message
    /// ever quotes an "offered" JSON value as (`refusal_wording.rb`'s
    /// `numeric_field` template: `"{type}.{field} expects {expected},
    /// got {offered}"` — `offered` is `value.inspect`, read directly). A
    /// String gets quoted (the same escaping `write_escaped_string`
    /// already does for the wire format); a number/bool prints bare;
    /// `nil`/arrays/objects are never actually offered where this is
    /// called (an Integer/Float-typed field's own wrong-shape value is
    /// always a scalar or explicit JSON `null` in practice) but fall
    /// back to something reasonable rather than panicking.
    pub fn inspect(&self) -> String {
        match self {
            Json::Str(s) => {
                let mut out = String::new();
                write_escaped_string(s, &mut out);
                out
            }
            Json::Null => "nil".to_string(),
            // Num/Bool/Array/Object — `to_json_string`'s own rendering
            // already matches Ruby's `.inspect` for a number or bool
            // (no quotes, same digit formatting `write`'s own fract==0.0
            // branch already gives); arrays/objects are never actually
            // offered here in practice, so this is a reasonable fallback
            // rather than a precise match for THAT case.
            _ => self.to_json_string(),
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    /// `None` for a fractional number, not a silent truncation — an
    /// `Integer`-typed field given `25.5` is a type mismatch Ruby's own
    /// `Value.for_attribute` coercion refuses, not "close enough." Also
    /// `None` for an integral-looking number outside `i64`'s own range —
    /// see `integral_i64`'s own comment. Ruby's `Integer` promotes to
    /// Bignum with no ceiling; this kernel has no arbitrary-precision type
    /// to promote to (zero Cargo dependencies, see this file's header), so
    /// every one of this function's callers is a generated `from_json`
    /// that already turns a `None` here into `Refusal::TypeMismatch` — a
    /// clean refusal, not the silent saturation Rust's own `as i64` cast
    /// would otherwise produce for a value past `i64::MAX`/`i64::MIN`.
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Num(n) => integral_i64(*n),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) | Json::Float(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    /// The RUNTIME half of a single-field value object's own bare-scalar
    /// admission — `rust/project/json_codec.rb`'s `emit_from_json_flat`/
    /// `emit_from_json_state` call this before handing a composite
    /// field's raw JSON to its own `from_json`, whenever the target type
    /// has exactly one attribute. Mirrors `Value.for_attribute`/
    /// `fields_for`'s own `value_object.attributes.size == 1` branch
    /// (lib/hecks/runtime/value/coercion.rb) — a caller's bare
    /// `"large"` for a `Size { value }` field isn't a shape error, it's
    /// the sole field's own value, unwrapped. Already-object input
    /// passes through unchanged (the wrapped `{"value": "large"}`
    /// spelling keeps working); anything else becomes a one-field object
    /// under `field_name`, the SAME field the target type's own
    /// `from_json` then looks up by name — so a genuinely wrong scalar
    /// (`Money.cents` given `"lots"`) still fails exactly where it
    /// always did, one level down inside that type's own field check,
    /// not here.
    pub fn coerce_single_field(&self, field_name: &str) -> Json {
        match self {
            Json::Object(_) => self.clone(),
            other => Json::obj(vec![(field_name, other.clone())]),
        }
    }

    /// A required-field lookup that raises the same `Refusal::TypeMismatch`
    /// every generated `from_json` raises for a missing/wrong-shaped field —
    /// shared here so the message wording is one place, not re-typed at
    /// every generated call site.
    pub fn require(&self, key: &str, struct_name: &str) -> Result<&Json, Refusal> {
        self.get(key)
            .ok_or_else(|| Refusal::TypeMismatch(format!("{struct_name}.{key}: missing from JSON args")))
    }

    /// `CommandInterpreter::ArgumentGate#refuse_unknown_arguments`'s own
    /// check, ported to the ONE place a command's JSON args has no static
    /// shape yet — before `from_json` builds the typed struct that makes an
    /// extra field structurally impossible to construct. `known` is the
    /// declared attributes plus whatever `json_codec.rb`'s
    /// `command_argument_allowlist` adds (identity heads, a command's own
    /// `reference_key`, every process manager's `correlation_head` in the
    /// domain — Ruby's own allowlist, read directly). Sorted, matching
    /// `ArgumentGate`'s own `.sort` — refusal wording is pinned by corpus
    /// fixtures on the Ruby side, so it can't depend on JSON key order.
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

    /// `registry.rs`'s own `stamp_payload` needs BOTH halves of the story
    /// an event's payload tells: the router's raw, unfiltered
    /// `args_json` (0013/0014's own fix — an identity-reference argument
    /// like `number:` isn't a declared struct field, so a saga's
    /// correlation forwarding needs it to survive onto the payload), AND
    /// the TYPED args struct's own `to_json()` (whose `from_json` already
    /// filled in any declared `default:` a bare/partial raw value never
    /// carried — `Transfer`'s own `amount` forwards `{"cents": N}` with no
    /// `currency` field at all into `Account.Debit`'s `PositiveMoney`,
    /// which DOES declare `currency: "USD"` as a default; Ruby's own
    /// event payload reflects the post-coercion value, this kernel's raw
    /// `args_json` alone does not). `overlay` merges them the way Ruby's
    /// own `payload: args` effectively already is (a coerced args hash,
    /// not the raw wire input) — for each top-level key `patch` declares,
    /// its value REPLACES `base`'s own (the fuller, defaulted nested
    /// value); every key `patch` doesn't touch (an identity/reference
    /// argument no declared attribute names) passes through from `base`
    /// unchanged. Non-`Object` inputs pass through `base` unchanged —
    /// nothing generated ever calls this on anything else.
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

    /// `ctx.args.merge(delegation.source.to_h { |target_key, source_key|
    /// [target_key, ctx.args[source_key]] })` —
    /// `CommandInterpreter#step_delegate_to_entity`, read directly: the
    /// facts a delegating door hands its entity command are the door's
    /// OWN args plus, under each target name the `with:` mapping
    /// declares, the door arg that mapping names. Same-named pairs are
    /// harmless re-assignments; a pair whose source the door never
    /// declared adds nothing, exactly as Ruby's `args[source_key]` is
    /// nil there. Non-`Object` receivers pass through unchanged.
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

    /// Stringifies a scalar leaf for identity-component joining —
    /// `extract_id`'s job (rust/project/json_codec.rb), the same "whatever
    /// it resolved to, make an id component out of it" coercion
    /// `Runtime::Identity.from` performs with `.to_s` on the Ruby side.
    ///
    /// R4 (docs/audits/2026-08-11-bug-triage.md) — an empty string is
    /// refused here the same way `Runtime::Identity.of` refuses one on
    /// the Ruby side: "A BLANK PART NAMES NOTHING, the same as an ABSENT
    /// one — AN ID IS A SCALAR, and '' is not a fact about anything"
    /// (`identity.rb`'s own comment, verbatim). Ruby's `Identity.of`
    /// treats a blank part as absent and returns `nil` for the WHOLE
    /// identity, refused later wherever the caller's own `|| raise(...)`
    /// chain bottoms out (dispatch time — `acting_no_identity`/
    /// `creating_no_identity`/`entity_parent_no_identity`, never a
    /// separate boot-time check). This kernel has no `nil`-vs-"identity
    /// resolved" distinction of its own to thread the same way; refusing
    /// HERE, at the one place every identity-component read funnels
    /// through (`extract_id`'s own `c0`/`c1` chain, each already wrapped
    /// in `.ok()?` — an `Err` here already reads as "this component
    /// didn't resolve" one level up, the same as a genuinely absent
    /// field), reaches the identical outcome at the identical pipeline
    /// stage: dispatch time, when this id is actually needed, not any
    /// earlier. Before this fix, an empty string round-tripped through
    /// unchanged and was accepted as a real, empty-string identity — a
    /// record silently addressable by an id no caller could have meant,
    /// and a real, persisted-state divergence from Ruby (which never
    /// persists such a record at all).
    pub fn to_id_component(&self) -> Result<String, Refusal> {
        match self {
            Json::Str(s) if s.is_empty() => {
                Err(Refusal::TypeMismatch("identity component must not be empty".to_string()))
            }
            Json::Str(s) => Ok(s.clone()),
            Json::Num(n) => match integral_i64(*n) {
                // In i64's own range: print as a plain integer, same as
                // Ruby's `.to_s` on a small-enough Integer.
                Some(i) => Ok(i.to_string()),
                // Outside i64's range (or non-integral): fall back to the
                // float's own digits rather than routing through the `as
                // i64` cast, which would silently saturate to
                // i64::MAX/i64::MIN instead of reflecting the real
                // magnitude. Still not a byte-for-byte match for Ruby's
                // exact Bignum digits (this kernel's `Json::Num` is `f64`
                // throughout, so precision beyond ~2^53 is already lost by
                // the time a wire value reaches here) — but a merely
                // imprecise identity component beats a wrong, clamped one.
                None => Ok(n.to_string()),
            },
            Json::Bool(b) => Ok(b.to_string()),
            other => Err(Refusal::TypeMismatch(format!("cannot use {other:?} as an identity component"))),
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
            Json::Num(n) => {
                if n.fract() == 0.0 && n.abs() < 1e15 {
                    out.push_str(&(*n as i64).to_string());
                } else {
                    out.push_str(&n.to_string());
                }
            }
            // Always a decimal point, even for a whole-number value --
            // matching Ruby's own Float#to_json (`10.0`, never bare `10`).
            // `Num`'s own branch, above, deliberately does the OPPOSITE
            // for a whole number, because it also carries Integer-typed
            // values, which must NOT grow a spurious `.0`. `n.to_string()`
            // already renders a fractional value correctly (`"3.5"`); the
            // only case needing help is a whole number, which f64's own
            // Display renders bare (`"10"`, no `.`/`e`).
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

/// Whether a JSON number is safely representable as an `i64` — both a
/// whole number (`fract() == 0.0`) AND within `i64::MIN..=i64::MAX`.
/// Every `Json::Num` is an `f64` (this file's own header: zero Cargo
/// dependencies, no arbitrary-precision integer type), and Rust's `as i64`
/// cast on an out-of-range float doesn't panic or truncate — it SATURATES
/// to `i64::MAX`/`i64::MIN` silently, which every direct `*n as i64` in
/// this file used to do unguarded. Ruby has no such ceiling (`Integer`
/// promotes to Bignum), so a value this kernel can't represent must be
/// refused (or, where the call site has no `Result` to refuse through,
/// handled some way OTHER than silently pretending it was `i64::MAX`) —
/// never quietly clamped into a wrong-but-plausible-looking number.
///
/// The bound check compares against `i64::MAX as f64`/`i64::MIN as f64`
/// rather than a hand-picked constant: `i64::MIN` (`-2^63`) is exactly
/// representable in `f64`, so `>=` is correct at that end; `i64::MAX`
/// (`2^63 - 1`) is NOT exactly representable and rounds UP to `2^63` when
/// widened to `f64`, so a strict `<` against that rounded value correctly
/// excludes `2^63` itself (which would saturate) while admitting every
/// float below it (all of which cast to `i64` without saturating).
fn integral_i64(n: f64) -> Option<i64> {
    if n.fract() == 0.0 && n >= i64::MIN as f64 && n < i64::MAX as f64 {
        Some(n as i64)
    } else {
        None
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
        // The largest f64 that still casts to i64 without saturating —
        // i64::MAX itself (2^63 - 1) isn't exactly representable in f64
        // and rounds up to 2^63, which is the saturation point rejected
        // by `accepts_i64_saturation_boundary` below.
        let largest_safe = 9223372036854774784.0_f64;
        assert_eq!(integral_i64(largest_safe), Some(largest_safe as i64));
    }

    #[test]
    fn accepts_i64_saturation_boundary() {
        // Refuses rather than silently saturating to i64::MAX/i64::MIN —
        // this is the L21 bug: `as i64` on either of these would produce
        // `i64::MAX`/`i64::MIN`, a wrong number that looks plausible.
        assert_eq!(integral_i64(2f64.powi(63)), None, "2^63 must not saturate to i64::MAX");
        // `f64`'s precision step this far from zero is already 2^11 (2048),
        // so nudging by a small delta can silently round back to the same
        // float — `2f64.powi(64)` (twice i64::MIN's magnitude) leaves no
        // ambiguity.
        assert_eq!(integral_i64(-(2f64.powi(64))), None, "well below i64::MIN must not saturate to i64::MIN");
    }

    #[test]
    fn as_i64_refuses_out_of_range_where_the_old_cast_would_have_saturated() {
        // A JSON number bigger than i64::MAX, e.g. from a huge command
        // argument — `Json::Num(n).as_i64()` used to silently become
        // `Some(i64::MAX)`. It must now be `None`, letting every generated
        // `from_json` call site's existing `.ok_or_else(|| Refusal::TypeMismatch(...))`
        // refuse cleanly instead.
        let huge = Json::Num(1e30);
        assert_eq!(huge.as_i64(), None);
    }

    #[test]
    fn to_id_component_reflects_true_magnitude_instead_of_a_clamped_one() {
        let huge = Json::Num(1e30);
        let id = huge.to_id_component().expect("numbers are always usable as an id component");
        assert_ne!(id, i64::MAX.to_string(), "must not silently clamp to i64::MAX");
        assert!(id.starts_with('1'), "should reflect the real magnitude, got {id:?}");
    }

    #[test]
    fn to_id_component_refuses_an_empty_string() {
        // R4 (docs/audits/2026-08-11-bug-triage.md) — Ruby's own
        // `Runtime::Identity.of` treats a blank identity part as absent,
        // never as a real, empty-string identity component. Before this
        // fix, `to_id_component` round-tripped `""` unchanged and Rust
        // silently accepted a record addressable by an empty-string id
        // that Ruby would never persist.
        let blank = Json::Str(String::new());
        assert!(blank.to_id_component().is_err(), "an empty string must not be usable as an identity component");
    }

    #[test]
    fn to_id_component_still_accepts_a_real_string() {
        let real = Json::Str("acct-1".to_string());
        assert_eq!(real.to_id_component().unwrap(), "acct-1");
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

// ── PARSER — recursive descent over `Peekable<Chars>`, not raw bytes:
// the input is already a valid `&str`, so walking chars sidesteps
// hand-rolling UTF-8 continuation-byte handling for no real benefit here.
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
        s.parse::<f64>().map(Json::Num).map_err(|e| format!("bad number {s:?}: {e}"))
    }
}
