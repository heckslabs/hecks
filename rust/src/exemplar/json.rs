// Exemplar shapes for rust/project/json_codec.rb; see mod.rs.
// Kept out of the fenced region so its prose is not baked into every generated codec.
#![allow(dead_code, unused_variables)]

use crate::exemplar::types::TmplKind;

// An `impl` block is a complete top-level item and needs no `tmpl_*_host` wrapper.
// TMPL:closed_set_codec BEGIN
impl TmplKind {
    pub fn to_json(&self) -> crate::kernel::Json {
        let member = match self {
            // TMPL:closed_set_codec:TO_JSON_ARM BEGIN
            TmplKind::TmplMemberA => "tmpl_member_a",
            // TMPL:closed_set_codec:TO_JSON_ARM END
        };
        crate::kernel::Json::obj(vec![("tmpl_field_name", crate::kernel::Json::str(member))])
    }

    pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
        // A `one_of` closed set is admission-checked on the raw offered
        // value, no shape check first — `Value::Admission#admit_member`
        // runs on whatever `Value::Coercion#fields_for` auto-wrapped into
        // the sole attribute's slot (a bare Array, a Bool, anything), never
        // on a value already known to be a String. `v.dig` gives the same
        // tolerant unwrap Ruby's own `fields_for` does: the wrapped
        // `{"tmpl_field_name": ...}` shape's inner value if `v` is an
        // object, or `v` itself untouched if it isn't (matching
        // `fields_for`'s single-field auto-wrap of a bare scalar/array/
        // whatever). Only then is admission checked — a non-member value
        // refuses `InvariantViolation`, matching Ruby's own refusal kind,
        // never `TypeMismatch` for a shape a member set never declared.
        //
        // BUG#14 (qa/bluebook/quality_control.bluebook) — a missing field
        // is not "a shape a member set never declared" the way a present-
        // but-wrong value is; it is `Value::Coercion#check_required_fields`
        // (runtime/value/coercion.rb) firing, and that check runs before
        // `admit_member` in `validate!`'s own order. A caller-supplied
        // `null` for a required command argument of this type is translated
        // by `required_composite_argument_expr` (json_codec.rb, BUG#4) into
        // an empty object — "build the value object from no fields at all",
        // matching `Value::Coercion#nil_argument`'s own `build(value_object,
        // {}, aggregate)` exactly — so `v.dig` above finding nothing is
        // genuinely indistinguishable, at this point, from a Hash-shaped
        // caller argument that simply never named the sole field's own key
        // either way: both are that field's own absence, not a member
        // mismatch.
        // Without this explicit null check, that absence would still fall
        // through to the admission match below, stringified as
        // `Json::Null`'s own `ruby_to_s` (never a real member), so a
        // required-but-omitted closed-set argument would misreport
        // `InvariantViolation` where Ruby raises `TypeMismatch`
        // ("{type}.{field} expects {expected}, got nil" — the same
        // `numeric_field` wording `required_field_expr` already gives
        // every other composite field's own missing-key case).
        let candidate = v.dig("tmpl_field_name").cloned().unwrap_or(crate::kernel::Json::Null);
        if matches!(candidate, crate::kernel::Json::Null) {
            return Err(crate::kernel::Refusal::TypeMismatch("tmpl_null_field_message".to_string()));
        }
        match candidate.ruby_to_s().as_str() {
            // TMPL:closed_set_codec:FROM_JSON_ARM BEGIN
            "tmpl_member_a" => Ok(TmplKind::TmplMemberA),
            // TMPL:closed_set_codec:FROM_JSON_ARM END
            _ => Err(crate::kernel::Refusal::InvariantViolation(
                crate::kernel::refusal_wording::InvariantViolationClosedSetMemberArgs {
                    r#type: "tmpl_closed_set_type",
                    admitted: &["tmpl_closed_set_member_a"],
                    offered: candidate.inspect().as_str(),
                }
                .render_args(),
            )),
        }
    }
}
// TMPL:closed_set_codec END

fn tmpl_json_value_placeholder() -> crate::kernel::Json {
    crate::kernel::Json::Null
}

// Standalone rather than nested so several outers can reuse it without copying its source.
fn tmpl_to_json_field_host() -> Vec<(String, crate::kernel::Json)> {
    vec![
        // TMPL:to_json_field BEGIN
        ("tmpl_field_name".to_string(), tmpl_json_value_placeholder()),
        // TMPL:to_json_field END
    ]
}

// A distinct type from `TmplKind`: two `impl TmplKind` blocks in one module would collide.
#[derive(Clone)]
struct TmplTableRow {
    tmpl_field: i64,
}

const TMPL_TABLE: &[TmplTableRow] = &[];

// Function-call placeholders; the marker sits flush left because plain `render` never reindents.
fn tmpl_to_json_fields_block() -> (String, crate::kernel::Json) {
    (String::new(), crate::kernel::Json::Null)
}

fn tmpl_from_json_conditions() -> bool {
    true
}

// TMPL:closed_set_table_codec BEGIN
impl TmplTableRow {
    pub fn to_json(&self) -> crate::kernel::Json {
        crate::kernel::Json::Object(vec![
tmpl_to_json_fields_block()
        ])
    }

    pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
        for row in TMPL_TABLE {
            if tmpl_from_json_conditions() {
                return Ok(row.clone());
            }
        }
        Err(crate::kernel::Refusal::TypeMismatch(format!("TmplTableRow: no member matches {:?}", v)))
    }
}
// TMPL:closed_set_table_codec END

// Stands in for `Json::as_str`/`as_i64`/`as_f64`; a bare associated item would not compile.
fn tmpl_accessor_fn(j: &crate::kernel::Json) -> Option<i64> {
    j.as_i64()
}

fn tmpl_from_json_condition_host(v: &crate::kernel::Json, row: &TmplTableRow) -> bool {
    // TMPL:closed_set_table_from_json_condition BEGIN
    v.get("tmpl_field_name").and_then(tmpl_accessor_fn) == Some(row.tmpl_field)
    // TMPL:closed_set_table_from_json_condition END
}

fn tmpl_rhs_placeholder() -> i64 {
    0
}

struct TmplFieldAssignmentHost {
    tmpl_ident: i64,
}
impl TmplFieldAssignmentHost {
    fn build() -> Self {
        Self {
            // TMPL:field_assignment BEGIN
            tmpl_ident: tmpl_rhs_placeholder(),
            // TMPL:field_assignment END
        }
    }
}

struct TmplFlatType2 {
    tmpl_ident: i64,
}

fn tmpl_to_json_field_block() -> (String, crate::kernel::Json) {
    (String::new(), crate::kernel::Json::Null)
}

// TMPL:to_json_flat BEGIN
impl TmplFlatType2 {
    pub fn to_json(&self) -> crate::kernel::Json {
        crate::kernel::Json::Object(vec![
tmpl_to_json_field_block()
        ])
    }
}
// TMPL:to_json_flat END

struct TmplFlatType3 {
    tmpl_ident: i64,
}

fn tmpl_to_json_field_block_sparse() -> (String, crate::kernel::Json) {
    (String::new(), crate::kernel::Json::Null)
}

// Drops `(key, Json::Null)` entries so an unset optional arg is an absent key, as in Ruby's
// `payload: args`. Command args only: records keep `null` for "declared, not set".
// TMPL:to_json_flat_sparse BEGIN
impl TmplFlatType3 {
    pub fn to_json(&self) -> crate::kernel::Json {
        crate::kernel::Json::Object(
            vec![tmpl_to_json_field_block_sparse()]
                .into_iter()
                .filter(|(_, v)| !matches!(v, crate::kernel::Json::Null))
                .collect(),
        )
    }
}
// TMPL:to_json_flat_sparse END

// The unknown-argument preamble is a full check block or empty; the no-op `let` keeps the
// exemplar compiling. Backs both `emit_from_json_flat` and `emit_from_json_state`.
// TMPL:from_json_flat BEGIN
impl TmplFlatType2 {
    pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
let _tmpl_unknown_check_placeholder = ();
        Ok(Self {
tmpl_ident: tmpl_rhs_placeholder(),
        })
    }
}
// TMPL:from_json_flat END

// `TIER1_LINE` is nested because only this one outer uses it. Method name and coercion are
// placeholders: the shape backs both strict `extract_id` and `extract_id_lenient`.
struct TmplExtractIdType;
// TMPL:extract_id BEGIN
impl TmplExtractIdType {
    pub fn tmpl_extract_id_name(v: &crate::kernel::Json) -> Result<String, crate::kernel::Refusal> {
        let by_identity = (|| -> Option<String> {
            // TMPL:extract_id:TIER1_LINE BEGIN
            let c0 = v.dig("tmpl_path")?.tmpl_id_coercion().ok()?;
            // TMPL:extract_id:TIER1_LINE END
            Some(tmpl_tier1_join_placeholder())
        })();
        let by_id_key = v.get("id").and_then(|j| j.tmpl_id_coercion().ok());
        let by_reference_key = v.get("tmpl_reference_key").and_then(|j| j.tmpl_id_coercion().ok());

        by_identity.or(by_id_key).or(by_reference_key).ok_or_else(|| {
            crate::kernel::Refusal::TypeMismatch("tmpl_error_text".to_string())
        })
    }
}
// TMPL:extract_id END

fn tmpl_tier1_join_placeholder() -> String {
    String::new()
}

// A real trait method so the exemplar compiles with the placeholder in place; codegen
// substitutes the method name only.
trait TmplIdCoercion {
    fn tmpl_id_coercion(&self) -> Result<String, crate::kernel::Refusal>;
}
impl TmplIdCoercion for crate::kernel::Json {
    fn tmpl_id_coercion(&self) -> Result<String, crate::kernel::Refusal> {
        self.to_id_component()
    }
}

// `element_of`'s `wants`, joined with ", ". Infallible: it is only read for a refusal
// message, so a missing path part yields an empty string.
struct TmplExtractWantsType;
// TMPL:extract_wants BEGIN
impl TmplExtractWantsType {
    pub fn extract_wants(v: &crate::kernel::Json) -> String {
        (|| -> Option<String> {
            // TMPL:extract_wants:TIER1_LINE BEGIN
            let c0 = v.dig("tmpl_path")?.to_id_component().ok()?;
            // TMPL:extract_wants:TIER1_LINE END
            Some(tmpl_wants_join_placeholder())
        })()
        .unwrap_or_default()
    }
}
// TMPL:extract_wants END

fn tmpl_wants_join_placeholder() -> String {
    String::new()
}

// Same shape as `extract_id`, over an already-built value instead of raw JSON.
struct TmplSelfIdentityType;
// TMPL:self_identity BEGIN
impl TmplSelfIdentityType {
    pub fn identity(&self) -> String {
        tmpl_identity_body_placeholder()
    }
}
// TMPL:self_identity END

fn tmpl_identity_body_placeholder() -> String {
    String::new()
}
