// EXEMPLAR shapes for rust/project/json_codec.rb — see mod.rs's own
// header. `closed_set_codec` is the to_json/from_json pair for
// `types.rs`'s own `closed_set_enum` — the two are separate exemplar
// items (matching separate Ruby functions, `emit_value_object`'s
// closed-set branch vs `emit_closed_set_codec`) but operate on the SAME
// enum type, so this file imports it rather than redeclaring it.
//
// TWO independent repeated slots inside ONE outer item — a to_json arm
// list and a from_json arm list, both driven by the same member rows but
// rendered as different arm shapes — is exactly what `Exemplar.assemble`
// (plural slots) exists for, where every other shape so far only needed
// `Exemplar.compose` (one slot).
//
// `from_json`'s final `other => ...` arm is `InvariantViolation`/
// `closed_set_member` — `admit_member` (runtime/value/admission.rb), read
// directly: a `one_of` membership check is an invariant on the value
// object being BUILT, never a shape mismatch, so this is
// `InvariantViolation`, not the `TypeMismatch` this arm raised before this
// migration. `admitted`/`offered` are both already `.inspect`-quoted the
// way Ruby's own `admitted.map(&:inspect).join(", ")`/`offered.inspect`
// are; the member list is baked in as codegen-time-known text
// (`json_codec.rb`'s `emit_closed_set_codec` already resolved every
// member at generation time), never re-derived from `TO_JSON_ARM` here.
// Kept OUT of the fenced region below on purpose — every word here would
// otherwise be baked into EVERY generated closed-set `from_json`, once
// per enum, across every domain.
#![allow(dead_code, unused_variables)]

use crate::exemplar::types::TmplKind;

// An `impl` block is already a complete top-level item — unlike Wave 1's
// single-statement shapes (constraints.rs, registry.rs), it needs no
// `tmpl_*_host` wrapper fn to give it real context. rustc agreed loudly
// the first time this was written nested inside one ("non-local `impl`
// definition" — real, if harmless, lint noise this tree holds itself to
// zero of).
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
        let raw = v.require("tmpl_field_name", "TmplKind")?.as_str()
            .ok_or_else(|| crate::kernel::Refusal::TypeMismatch("TmplKind.tmpl_field_name: expected string".to_string()))?;
        match raw {
            // TMPL:closed_set_codec:FROM_JSON_ARM BEGIN
            "tmpl_member_a" => Ok(TmplKind::TmplMemberA),
            // TMPL:closed_set_codec:FROM_JSON_ARM END
            other => Err(crate::kernel::Refusal::InvariantViolation(crate::kernel::RefusalSite::InvariantViolationClosedSetMember.render(&[
                ("type", "tmpl_closed_set_type"),
                ("admitted", "tmpl_closed_set_admitted"),
                ("offered", &format!("{:?}", other)),
            ]))),
        }
    }
}
// TMPL:closed_set_codec END

fn tmpl_json_value_placeholder() -> crate::kernel::Json {
    crate::kernel::Json::Null
}

// `to_json_field` — ONE `(key, value)` entry inside a `Json::Object(vec![
// ...])` body. Reused verbatim by `closed_set_table_codec` below AND by
// the plain to_json shapes (`to_json_flat`/`to_json_state`, once that
// wave lands) — deliberately NOT nested inside any one of them the way
// `closed_set_enum:VARIANT` is nested inside `closed_set_enum`: nesting
// would mean physically duplicating this shape's source into every
// outer that wants it, two copies free to drift apart. A shape meant for
// more than one outer stays a standalone top-level item; Ruby renders it
// with plain `render_each`, adds whatever fixed indent the call site
// needs (the same indent the ORIGINAL hand-interpolated string already
// baked in), and hands the joined block to the outer as an ordinary
// substitution value — not through `compose`/`assemble`'s nested-slot
// machinery, which is for a leaf one specific outer alone owns.
fn tmpl_to_json_field_host() -> Vec<(String, crate::kernel::Json)> {
    vec![
        // TMPL:to_json_field BEGIN
        ("tmpl_field_name".to_string(), tmpl_json_value_placeholder()),
        // TMPL:to_json_field END
    ]
}

// `closed_set_table_codec` — the to_json/from_json pair for `types.rs`'s
// own `closed_set_table`. `tmpl_to_json_fields_block()`/
// `tmpl_from_json_conditions()` are the function-call placeholder idiom
// (same as `tmpl_body_placeholder()`, reactions.rs) rather than a bare
// identifier: Ruby's replacement text is ALREADY fully rendered+joined
// (`to_json_field` above, joined and indented exactly the way the
// original hand-built string did; a small condition-line shape below,
// joined by " && "), handed in as a plain substitution value — not
// `compose`/`assemble`'s nested-slot mechanism, because neither piece
// needs auto-reindent (the to_json block's indent is fixed regardless of
// nesting depth, matching the ORIGINAL code's own behavior byte-for-
// byte; the from_json conditions render onto one line). The call's own
// column-0 position (not indented like the rest of the method body) is
// deliberate too — plain `render` never reindents a multi-line
// replacement the way `compose` does, so the marker sits flush left and
// each line of Ruby's already-8-space-prefixed block lands untouched.
// A DIFFERENT placeholder type from `closed_set_codec`'s own `TmplKind`
// above — real, since the two Ruby functions this file's shapes back
// (`emit_closed_set_codec` vs `emit_closed_set_table_codec`) never fire
// for the same value object (`types.rb`'s own `vo[:attributes].size > 1`
// branch is exactly the fork), but `impl TmplKind { .. }` twice in one
// module is a duplicate-definition error regardless of which Ruby
// function would really call which — the exemplar has to name two
// distinct types even where the real generators never would collide.
#[derive(Clone)]
struct TmplTableRow {
    tmpl_field: i64,
}

const TMPL_TABLE: &[TmplTableRow] = &[];

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

// `tmpl_accessor_fn` — the function-call placeholder idiom again, this
// time standing in for WHICHEVER of `Json::as_str`/`as_i64`/`as_f64`
// the real field's scalar type resolves to (`SCALAR_JSON_ACCESSOR`,
// json_codec.rb). A bare `crate::kernel::Json::tmpl_accessor` wouldn't
// compile unsubstituted (no such associated item), so this shape gives
// the marker a real function of the matching signature to point at
// instead — Ruby's substitution then swaps the whole call target for
// the real qualified path (`crate::kernel::Json::as_i64`, say).
fn tmpl_accessor_fn(j: &crate::kernel::Json) -> Option<i64> {
    j.as_i64()
}

fn tmpl_from_json_condition_host(v: &crate::kernel::Json, row: &TmplTableRow) -> bool {
    // TMPL:closed_set_table_from_json_condition BEGIN
    v.get("tmpl_field_name").and_then(tmpl_accessor_fn) == Some(row.tmpl_field)
    // TMPL:closed_set_table_from_json_condition END
}

// `to_json_flat`/`from_json_flat` — the JSON boundary for value objects
// and command Args structs (entities/records get `to_json` only —
// json_codec.rb's own header on why). The RHS-computing helpers
// (`scalar_from_json_expr` and friends, json_codec.rb) stay plain Ruby
// string-building, deliberately: they're low-risk, single-expression
// assembly (matching `render_each`'s own `join_with` precedent), and the
// real structural risk — getting an `impl`/struct-literal/match brace
// wrong — lives in the OUTER skeletons here, not in which accessor
// method a scalar type resolves to.
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

// The unknown-argument-check preamble is EITHER a real, multi-line,
// already-fully-built block (`emit_unknown_argument_check`, unchanged
// plain Ruby) OR empty — `from_json_state` (json_codec.rb) always
// passes empty, since only an AGGREGATE command's own top-level args
// struct ever runs this check (json_codec.rb's own header). A no-op
// `let` statement is the fixed default so the exemplar compiles
// standalone; Ruby substitutes either this exact text or the real
// check block, same reasoning as `fielded_flat`'s own conditional
// `use crate::kernel::Value;` marker. This SAME shape backs BOTH
// `emit_from_json_flat` and `emit_from_json_state` (json_codec.rb) —
// structurally identical; only the preamble and each field's RHS
// (plain Ruby, `field_assignment`'s own header) differ between them.
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

// `extract_id` — an aggregate's own identity, read straight off the
// incoming JSON step args (json_codec.rb's own header: the three-tier
// chain `hydrate`'s own acting-command identity resolution needs).
// `TIER1_LINE`, nested (not standalone like `field_assignment`/
// `to_json_field`): single-use, only ever called from ONE outer
// (`emit_extract_id`), so `compose`'s auto-reindent is the right tool —
// no duplication risk when nothing else ever wants this exact leaf.
struct TmplExtractIdType;
// TMPL:extract_id BEGIN
impl TmplExtractIdType {
    pub fn extract_id(v: &crate::kernel::Json) -> Result<String, crate::kernel::Refusal> {
        let by_identity = (|| -> Option<String> {
            // TMPL:extract_id:TIER1_LINE BEGIN
            let c0 = v.dig("tmpl_path")?.to_id_component().ok()?;
            // TMPL:extract_id:TIER1_LINE END
            Some(tmpl_tier1_join_placeholder())
        })();
        let by_id_key = v.get("id").and_then(|j| j.to_id_component().ok());
        let by_reference_key = v.get("tmpl_reference_key").and_then(|j| j.to_id_component().ok());

        by_identity.or(by_id_key).or(by_reference_key).ok_or_else(|| {
            crate::kernel::Refusal::TypeMismatch("tmpl_error_text".to_string())
        })
    }
}
// TMPL:extract_id END

fn tmpl_tier1_join_placeholder() -> String {
    String::new()
}

// `extract_wants` — `element_of`'s own `wants` (entity_interpreter.rb),
// for `dispatch_entity`'s `entity_element_missing` refusal message. The
// SAME TIER1 dig `extract_id` above performs (an entity command's own
// identity paths are ALWAYS present by the time this is worth computing —
// `element_of` raises `entity_element_no_identity` first if any part is
// missing, so Ruby's own `wants` never falls back to an `id`/reference-key
// tier the way `extract_id`'s THREE-tier chain does), joined with ", "
// rather than ":" — `wants.map { |_h, path, want| Identity.scalar(path,
// want) }.join(", ")`, read directly. Infallible (`String`, not
// `Result<String, Refusal>`): this is ONLY ever read for a refusal
// MESSAGE, never to address a record, so a genuinely unreachable missing
// part degrades to an empty string rather than a second way for dispatch
// itself to fail.
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

// `self_identity` — the SAME dotted-path/join-with-":" shape as
// `extract_id`, applied to an already-constructed Rust value instead of
// raw JSON (`self.field` in place of `v.get(...)`) — an entity
// element's own identity, for `dispatch_entity`'s `matches` closure.
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
