//! The `Aggregate` construct (`lib/hecksagain/bluebook/ir/aggregate.rb`,
//! built by `Hecksagain::Bluebook::DSL::AggregateBuilder`). STAGE 3 adds
//! the MULTI-PATH `identified_by do ... end`/`identified_by { ... }`
//! source form (`build/identity.rs`'s own header explains why it needs no
//! `build/*.rs` derivation at all — its body IS the identity, captured
//! raw) and inline `one_of(...)` closed-set synthesis
//! (`build/closed_sets.rs`) folded into this aggregate's own
//! `value_objects`. STAGE 4 adds `provenance` (a raw captured Hash,
//! `ir::Literal` — see `ir.rs`'s own comment), a nested `policy` (hoisted
//! onto the CHAPTER by Ruby's own `AggregateBuilder#policy`, so this
//! module returns it SEPARATELY rather than folding it into
//! `ir::Aggregate` — `parse::chapter`'s own header explains the bubbling
//! order), `belongs_to`/`has_one` (`has_many` stays unbuilt — no real
//! corpus member exercises it yet), and a real `entity` (`parse::entity`,
//! previously fully stubbed). Still open: the bare-FIELD `identified_by`
//! form (`identified_by :field`, not exercised by any real corpus member
//! yet).

use super::{command, entity, lifecycle, policy, query, value_object};
use crate::build::{identity, naming, references};
use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Aggregate.{word}"))
}

/// Parses an `aggregate "Name" do ... end` body. `identified_by`'s TYPE
/// form is DEFERRED to the end (mirroring `AggregateBuilder#build`'s own
/// `resolve_pending_identity!`, called only once every `value_object`
/// inside this same body has been declared) — pizzas.bluebook's own
/// `PizzaName` value object is declared AFTER `identified_by PizzaName,
/// as: :name`, so resolving eagerly would find no value objects yet. The
/// SOURCE (block) form needs no such deferral — its paths are already
/// literal text, not a lookup — so it's resolved immediately, matching
/// `AggregateBuilder#identified_by`'s own `@identity_paths = paths`
/// direct assignment.
///
/// Inline `one_of(...)` closed sets (`attribute :tone, one_of(...)`) are
/// collected SEPARATELY from `value_object "Name" do ... end` blocks and
/// appended AFTER them — mirroring `AggregateBuilder#build`'s own
/// `@value_objects + closed_sets` ORDER exactly (confirmed against
/// console_settings.bluebook's own `StateStyle`: its three explicit
/// `value_object`s come first in `ir.json`, `Tone` — synthesized from
/// `attribute :tone, one_of(...)`, written BEFORE two of those three in
/// the source — comes last regardless).
/// Returns the built aggregate ALONGSIDE any `policy`s declared directly
/// inside it — `AggregateBuilder#policy` HOISTS a nested policy onto the
/// CHAPTER (`IR::Policy#aggregate`'s own comment: "a policy written
/// inside an aggregate is HOISTED onto the chapter by the builder"), and
/// `IR::Aggregate#to_h` never spells `policies` at all — confirmed by
/// reading `aggregate.rb` directly. So this can't fold a nested policy
/// into `ir::Aggregate` the way it does `commands`/`queries`/etc; the
/// caller (`parse::chapter`) bubbles the returned `Vec<ir::Policy>` onto
/// `ir::Bluebook.policies` itself, in the exact order
/// `BluebookBuilder#build`'s own `@aggregates.flat_map(&:policies) +
/// @policies` produces (every aggregate's own policies, in aggregate
/// order, THEN every chapter-level one).
/// BARE `given(desc)` — CHAPTER-WIDE REFERENCE
/// (`docs/implemented/resolution-rules/chapter-given.md`). Mirrors `parse::command::
/// try_reference_named_given`'s own shape one level up: peeks the next
/// physical line WITHOUT consuming it unless it actually matches (word
/// `given`, `Opener::None`) — anything else (a fresh `given("x") { ... }`
/// declaration, or any other word entirely) falls through untouched to
/// the ordinary `next_line` gate, which already handles it.
///
/// `AggregateBuilder#given`'s own bare-reference form has no narrower
/// "in-between" scope to check first — an aggregate is not nested inside
/// anything else `given` could mean here — so, unlike the command-level
/// version, there is only ONE pool to check: `chapter_named_givens`.
///
/// KEYED BY (owner name, `Given`) PAIRS, not a flat `Given` list — a
/// SECOND aggregate can independently declare the SAME description under
/// a genuinely DIFFERENT canonical (real corpus: `Account`'s own
/// "customer is active" reads bare `customer.status`; `ATMCard`'s own
/// reads `account.customer.status`, reached through `Account`), so this
/// mirrors `AggregateBuilder#given`'s own Ruby-side `declared_by:`
/// disambiguation (`docs/implemented/resolution-rules/chapter-given.md`) rather than
/// the earlier single-candidate-only shape: an OPTIONAL `declared_by:
/// SomeAggregate` argument picks the exact owner when more than one
/// candidate is registered under the same description; omitted, it
/// resolves only when EXACTLY one candidate exists — never guesses among
/// several.
fn try_reference_named_chapter_given(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    chapter_named_givens: &[(String, ir::Given)],
) -> ParseResult<Option<ir::Given>> {
    let Some(&line) = lines.get(*pos) else {
        return Ok(None);
    };
    let LineShape::Call(call) = lex::classify(file, &line)? else {
        return Ok(None);
    };
    if call.word != "given" || !matches!(call.opener, Opener::None) {
        return Ok(None);
    }

    super::verify_resolves_via(file, line.number, "given", "Aggregate", "owner_keyed")?;

    let args = super::argument_gate(file, "given", "Aggregate", &call.args, line.number)?;
    let description = super::positional_text(file, line.number, "given", &args, 1)?;
    let declared_by =
        super::named_raw(&args, "declared_by").map(|raw| naming::demodulise(raw.trim()));

    let candidates: Vec<&(String, ir::Given)> = chapter_named_givens
        .iter()
        .filter(|(_, given)| given.description.as_deref() == Some(description.as_str()))
        .collect();

    let resolved = if let Some(owner) = declared_by {
        candidates
            .iter()
            .find(|(candidate_owner, _)| candidate_owner == &owner)
            .map(|(_, given)| given.clone())
            .ok_or_else(|| {
                Diagnostic::new(
                    file,
                    line.number,
                    format!(
                        "'{description}' names no precondition {owner} declares in this chapter \
                         — {owner} either hasn't declared '{description}', or declared_by: named \
                         the wrong aggregate"
                    ),
                )
            })?
    } else {
        match candidates.as_slice() {
            [] => {
                return Err(Diagnostic::new(
                    file,
                    line.number,
                    format!(
                        "'{description}' names no precondition any aggregate in this chapter has \
                         declared yet — declare it once with a block, before the aggregates that \
                         reference it"
                    ),
                ))
            }
            [(_, given)] => given.clone(),
            _ => {
                let owners: Vec<&str> =
                    candidates.iter().map(|(owner, _)| owner.as_str()).collect();
                return Err(Diagnostic::new(
                    file,
                    line.number,
                    format!(
                        "'{description}' is ambiguous in this chapter — {} each declare a \
                         DIFFERENT predicate under this same description; name which one with \
                         declared_by:",
                        owners.join(", ")
                    ),
                ));
            }
        }
    };

    *pos += 1;
    Ok(Some(resolved))
}

pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    chapter_named_givens: &mut Vec<(String, ir::Given)>,
) -> ParseResult<(ir::Aggregate, Vec<ir::Policy>)> {
    let mut aggregate = ir::Aggregate {
        name: name.to_string(),
        ..Default::default()
    };
    let mut pending_identity: Option<super::PendingIdentity> = None;
    let mut closed_sets: Vec<ir::ValueObject> = Vec::new();
    let mut policies: Vec<ir::Policy> = Vec::new();
    // DEFERRED CONSTRUCTION — see `parse::mod::PendingBody`'s own header.
    // `entity`/`command`/`query` only QUEUE here; built for real by the
    // drain below, once this aggregate's own top-level line-range is
    // fully walked and `aggregate.value_objects`/`.entities`/
    // `.preconditions`/`.attributes` are the real, final lists —
    // mirroring `AggregateBuilder#drain_pending!` one for one.
    let mut pending_entities: Vec<(String, super::PendingBody)> = Vec::new();
    let mut pending_commands: Vec<(String, Option<ir::CommandFrom>, super::PendingBody)> =
        Vec::new();
    let mut pending_queries: Vec<(String, super::PendingBody)> = Vec::new();
    // THE ROOT of the cross-entity given pool
    // (`docs/resolution-rules/cross-entity-given.md`) — ONE `Vec`, owned
    // here, threaded as a mutable borrow into every piece this aggregate
    // builds however deep (`entity::parse_body`'s own header). Always
    // empty when read back for THIS aggregate's own commands, below — an
    // aggregate-owned command has no sibling piece to reach across.
    let mut entity_named_givens: Vec<ir::Given> = Vec::new();

    loop {
        // BARE `given(desc)` — CHAPTER-WIDE REFERENCE
        // (`docs/implemented/resolution-rules/chapter-given.md`) — peeked BEFORE the
        // ordinary grammar-gated `next_line` below, the identical trick
        // `parse::command::try_reference_named_given`'s own header
        // explains: `syntax.bluebook`'s own grammar row for `given`/
        // Aggregate still declares `body: "source"` (block required) —
        // unchanged, on purpose, since a FRESH declaration still needs
        // one — so a genuinely bare `given` has to be recognized and
        // consumed HERE, by raw lexing, before that gate would refuse it.
        if let Some(given) =
            try_reference_named_chapter_given(file, lines, pos, chapter_named_givens)?
        {
            aggregate.preconditions.push(given);
            continue;
        }

        let Some(gated) = super::next_line(file, lines, pos, "Aggregate")? else {
            break;
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => {
                aggregate.description = Some(super::positional_text(
                    file,
                    line,
                    "description",
                    &gated.args,
                    1,
                )?)
            }
            // `AggregateBuilder#provenance(from:)` — ORIGIN, not identity:
            // captured raw, the same "whatever the author wrote" shape
            // `attribute ..., default: { ... }` already uses for a
            // literal Hash. `IR::Aggregate#to_h`'s own `provenance:
            // @provenance` embeds the raw Ruby Hash straight into
            // `JSON.generate`, never through `Literal.render` — see
            // `ir::Literal`'s own header and `ir.rs::Aggregate.provenance`'s
            // comment. Confirmed real: banking.bluebook's own `Account`.
            "provenance" => {
                let raw = super::named_raw(&gated.args, "from")
                    .ok_or_else(|| Diagnostic::new(file, line, "'provenance' requires a from:"))?;
                aggregate.provenance = Some(ruby_value::read(raw.trim()));
            }
            "attribute" => {
                let (attr, vo) = super::build_attribute(file, line, "attribute", &gated.args)?;
                aggregate.attributes.push(attr);
                if let Some(vo) = vo {
                    closed_sets.push(vo);
                }
            }
            "identified_by" => {
                if pending_identity.is_some() {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!("{name} declares identified_by more than once"),
                    ));
                }
                let inline_type_name = format!("{}Identity", naming::demodulise(name));
                let owner_value_objects: Vec<ir::ValueObject> = aggregate
                    .value_objects
                    .iter()
                    .chain(closed_sets.iter())
                    .cloned()
                    .collect();
                let parsed = super::parse_identified_by(
                    file,
                    lines,
                    pos,
                    line,
                    &gated.args,
                    &gated.call.opener,
                    aggregate.attributes.len(),
                    &inline_type_name,
                    &owner_value_objects,
                )?;
                pending_identity = Some(match parsed {
                    super::PendingIdentity::Inline {
                        line,
                        value_object,
                        as_field,
                        insert_at,
                    } => {
                        if aggregate
                            .value_objects
                            .iter()
                            .chain(closed_sets.iter())
                            .any(|existing| existing.name == value_object.name)
                        {
                            return Err(Diagnostic::new(
                                file,
                                line,
                                format!(
                                    "{name}.identified_by synthesizes duplicate value object {}",
                                    value_object.name
                                ),
                            ));
                        }
                        let target = value_object.name.clone();
                        aggregate.value_objects.push(value_object);
                        super::PendingIdentity::Type {
                            line,
                            target,
                            as_field: Some(as_field.unwrap_or_else(|| "identity".to_string())),
                            insert_at,
                        }
                    }
                    other => other,
                });
            }
            // `AggregateBuilder#reference_to(type, as: nil)` — mints a
            // reference attribute directly on the aggregate, the SAME
            // shape `references::reference_attribute` already builds for
            // a command's own `reference_to` (`command.rs`'s
            // `apply_reference_to`). Confirmed real: identity.bluebook's
            // own `ExternalIdentifier` (`reference_to Identity`, no
            // `as:` — mints `identity_id`). Unlike the command form,
            // there's no "self-reference means acts_on, not an
            // attribute" distinction here at all — an aggregate's own
            // `reference_to` is ALWAYS an attribute mint.
            "reference_to" => {
                let target_raw =
                    super::positional_constant(file, line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as");
                let optional = super::named_flag(&gated.args, "optional");
                aggregate.attributes.push(references::relationship_attribute(
                    &target,
                    "reference_to",
                    as_name.as_deref(),
                    optional,
                    false,
                ));
            }
            // `has_one`/`belongs_to` — sugar over `reference_to` minting
            // NO `_id` suffix (`AggregateBuilder#has_one`: `reference_to(type,
            // as: as || Naming.snake(Naming.demodulise(type)).to_sym)`),
            // `belongs_to` a bare alias of `has_one`. Confirmed real:
            // banking.bluebook's own `OnboardingCase` (`belongs_to
            // Customer` mints a plain `customer` attribute, not
            // `customer_id`).
            "has_one" | "belongs_to" => {
                let target_raw =
                    super::positional_constant(file, line, gated.row.word, &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                let as_name = super::named_symbol(&gated.args, "as")
                    .unwrap_or_else(|| naming::snake(&target));
                let optional = super::named_flag(&gated.args, "optional");
                aggregate
                    .attributes
                    .push(references::relationship_attribute(
                        &target,
                        gated.row.word,
                        Some(&as_name),
                        optional,
                        false,
                    ));
            }
            // `has_many` — the SAME sugar, but `reference_to(Naming
            // .singularize(plural), as: as || Naming.snake(plural).to_sym)`:
            // the TARGET named is singularized (`has_many Invoices` points
            // at `Invoice`) while the minted attribute's own name keeps
            // the PLURAL spelling as written. Declared in syntax.bluebook
            // but not exercised by any real corpus member yet — built
            // anyway (identical shape to `has_one` above, near-zero extra
            // risk), kept correct rather than left a guess.
            "has_many" => {
                let plural_raw =
                    super::positional_constant(file, line, "has_many", &gated.args, 1)?;
                let plural = naming::demodulise(plural_raw);
                let target = naming::singularize(&plural);
                let as_name = super::named_symbol(&gated.args, "as")
                    .unwrap_or_else(|| naming::snake(&plural));
                let optional = super::named_flag(&gated.args, "optional");
                aggregate
                    .attributes
                    .push(references::relationship_attribute(
                        &target,
                        "has_many",
                        Some(&as_name),
                        optional,
                        true,
                    ));
            }
            // THE AGGREGATE BOUNDARY (S10, ADR 0025 — "Rules") — the same
            // `source`-body capture `value_object::parse_body`'s own
            // `invariant` arm already does, one level up (that module's
            // own header explains the two legal spellings).
            "invariant" => {
                let description = super::positional_text(file, line, "invariant", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                aggregate.invariants.push(ir::Given {
                    description: Some(description),
                    canonical: canonical::apply(&raw),
                });
            }
            // A PRECONDITION SHARED ACROSS COMMANDS, DECLARED ONCE (S10,
            // ADR 0025) — block REQUIRED here (`syntax.bluebook`'s own
            // row: only ONE row for `given`/Aggregate, `body: "source"`),
            // a fresh declaration. The BARE form (no block, a CHAPTER-
            // WIDE reference — `docs/implemented/resolution-rules/chapter-given.md`)
            // is peeked and consumed BEFORE `next_line` ever reaches this
            // match arm at all — see `try_reference_named_chapter_given`,
            // above the loop.
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                let built = ir::Given {
                    description: Some(description.clone()),
                    canonical: canonical::apply(&raw),
                };
                aggregate.preconditions.push(built.clone());
                // WRITE-THROUGH, first-declared-wins PER OWNER — keyed
                // by (description, this aggregate's own name), not
                // description alone (Ruby's own `pool[description]
                // [owner_name] ||=`, one Rust `Vec<(owner, Given)>` pair
                // standing in for that nested Hash — Rust has no
                // `Hash#||=`, so this checks "no existing entry for THIS
                // exact [description, owner] pair" before pushing). A
                // DIFFERENT owner independently declaring the identical
                // description registers its OWN entry alongside, never
                // overwriting another owner's — see
                // `try_reference_named_chapter_given`'s own header for
                // why (the real corpus case this disambiguates).
                if !chapter_named_givens.iter().any(|(owner, g)| {
                    owner == name && g.description.as_deref() == Some(description.as_str())
                }) {
                    chapter_named_givens.push((name.to_string(), built));
                }
            }
            // A FIELD READ THROUGH A REFERENCE, HELD LOCALLY (S12, ADR
            // 0025 — "Consistency across aggregate boundaries") —
            // `from:` names a dotted path, split on the LAST "." the
            // same way `AggregateBuilder#projects`'s own
            // `from.to_s.rpartition(".")` does: `reference` is
            // everything before it, `remote_field` the bare name
            // after. TARGET-side resolution (does the reference
            // actually resolve, does the remote aggregate actually
            // declare that field) stays Ruby-DSL-builder-only, the
            // same as a command's own block-less `given` above —
            // `BluebookBuilder#validate_projected_fields!` needs the
            // WHOLE chapter assembled, which this single-aggregate
            // parse never has.
            "projects" => {
                let field_name = super::positional_symbol(file, line, "projects", &gated.args, 1)?;
                let from = super::named_symbol(&gated.args, "from")
                    .ok_or_else(|| Diagnostic::new(file, line, "'projects' requires a from:"))?;
                let Some((reference, remote_field)) = from.rsplit_once('.') else {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!("'projects' from: '{from}' is not reference.field"),
                    ));
                };
                aggregate.projected_fields.push(ir::ProjectedField {
                    name: field_name,
                    reference: reference.to_string(),
                    remote_field: remote_field.to_string(),
                });
            }
            // `owner_value_objects` — `AggregateBuilder#value_object`'s own
            // `owner_value_objects: @value_objects + closed_sets`, SO FAR
            // (source order): this aggregate's own explicit value objects
            // built by earlier iterations of THIS loop, plus any inline
            // `attribute :x, one_of(...)` closed set synthesized by an
            // earlier `attribute` line — the two Vecs `value_object::
            // parse_body`'s own `try_reference_named_invariant` resolves a
            // bare `invariant("...")` against. Combined fresh on every
            // `value_object` line (not threaded as a running Vec) since
            // `aggregate.value_objects`/`closed_sets` are two separate
            // local Vecs, each still growing.
            "value_object" => {
                let vo_name = super::positional_text(file, line, "value_object", &gated.args, 1)?;
                let owner_value_objects: Vec<ir::ValueObject> = aggregate
                    .value_objects
                    .iter()
                    .chain(closed_sets.iter())
                    .cloned()
                    .collect();
                let vo = super::parse_nested_body(
                    file,
                    lines,
                    pos,
                    &gated.call.opener,
                    line,
                    |f, l, p| value_object::parse_body(f, l, p, &vo_name, &owner_value_objects),
                )?;
                aggregate.value_objects.push(vo);
            }
            "lifecycle" => {
                let field = super::positional_symbol(file, line, "lifecycle", &gated.args, 1)?;
                let default = super::named_text(&gated.args, "default").ok_or_else(|| {
                    Diagnostic::new(file, line, "'lifecycle' requires a default:")
                })?;
                aggregate.lifecycle =
                    Some(lifecycle::parse_body(file, lines, pos, &field, &default)?);
            }
            // DEFERRED CONSTRUCTION — see `parse::mod::PendingBody`'s own
            // header. `AggregateBuilder#entity` now only QUEUES too; the
            // real build happens in the drain below, against this
            // aggregate's COMPLETE `value_objects` (this one's own TYPE-
            // form `identified_by` — and, one level down, its own
            // entities'/commands' resolution — needs the FULL set, not
            // just what was declared textually before this line: a
            // value_object declared AFTER an entity that identifies by
            // it is real, confirmed corpus shape —
            // `model_check/lifecycle_findings.bluebook`'s own `Part`).
            "entity" => {
                let e_name = super::positional_text(file, line, "entity", &gated.args, 1)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_entities.push((e_name, pending));
            }
            "query" => {
                let q_name = super::positional_text(file, line, "query", &gated.args, 1)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_queries.push((q_name, pending));
            }
            "command" => {
                let c_name = super::positional_text(file, line, "command", &gated.args, 1)?;
                let from = command::parse_from(file, line, &gated.args)?;
                let pending = super::defer_body(file, lines, pos, &gated.call.opener, line)?;
                pending_commands.push((c_name, from, pending));
            }
            // `AggregateBuilder#policy` — see this function's own header
            // on why the built `ir::Policy` is returned rather than
            // folded into `aggregate` itself.
            "policy" => {
                let p_name = super::positional_text(file, line, "policy", &gated.args, 1)?;
                policies.push(policy::parse_body(file, lines, pos, &p_name)?);
            }
            _ => {
                return Err(super::not_built_yet(
                    "Aggregate",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }

    // EXPLICIT value objects first, closed sets appended after — see this
    // function's own header. Done BEFORE resolving a pending TYPE-form
    // identity, matching Ruby's own `resolve_identity_type!(..., @value_objects
    // + closed_sets, ...)` call — the target value object a TYPE-form
    // `identified_by` names could, in principle, itself be an inline
    // closed set (not exercised by any real corpus member today, kept
    // correct anyway).
    let mut identity_value_object_insert_at = aggregate.value_objects.len();
    aggregate.value_objects.extend(closed_sets);

    // DEFERRED CONSTRUCTION, DRAINED — `AggregateBuilder#drain_pending!`'s
    // own mirror, in the SAME order (entities first and fully, then
    // commands, then queries), run AFTER `aggregate.value_objects` is the
    // real, final, merged list above and BEFORE this aggregate's own
    // pending identity resolves (matching `AggregateBuilder#build`'s own
    // `drain_pending!` then `resolve_pending_identity!` order exactly —
    // the two don't actually depend on each other, but nothing is lost by
    // keeping the identical order). Declared-order preserved throughout:
    // each `pending_*` Vec was pushed to in textual order and `.map` walks
    // it in that same order, so `aggregate.entities`/`.commands`/
    // `.queries` end up in the SAME order they always did.
    // AN EXPLICIT LOOP — see `entity::parse_body`'s own identical
    // conversion, one level down, for why: `entity_named_givens` reborrows
    // sequentially into each piece's own recursive build, so a
    // LATER-declared piece sees an EARLIER sibling's write-through.
    let mut entities = Vec::with_capacity(pending_entities.len());
    for (e_name, pending) in pending_entities {
        let built = super::build_deferred(file, lines, &pending, |f, l, p| {
            entity::parse_body(
                f,
                l,
                p,
                &e_name,
                &format!(
                    "{}{}",
                    naming::demodulise(name),
                    naming::demodulise(&e_name)
                ),
                &mut aggregate.value_objects,
                &mut identity_value_object_insert_at,
                &mut entity_named_givens,
            )
        })?;
        entities.push(built);
    }
    aggregate.entities = entities;

    aggregate.commands = pending_commands
        .into_iter()
        .map(|(c_name, from, pending)| {
            super::build_deferred(file, lines, &pending, |f, l, p| {
                command::parse_body(
                    f,
                    l,
                    p,
                    &c_name,
                    name,
                    from.clone(),
                    &aggregate.preconditions,
                    &[],
                    &aggregate.attributes,
                    &aggregate.value_objects,
                    &aggregate.entities,
                )
            })
        })
        .collect::<ParseResult<Vec<_>>>()?;

    aggregate.queries = pending_queries
        .into_iter()
        .map(|(q_name, pending)| {
            super::build_deferred(file, lines, &pending, |f, l, p| {
                query::parse_body(f, l, p, &q_name)
            })
        })
        .collect::<ParseResult<Vec<_>>>()?;

    if let Some(pending) = pending_identity {
        match pending {
            super::PendingIdentity::Type {
                line,
                target,
                as_field,
                insert_at,
            } => {
                aggregate.identified_by = identity::resolve_identity_type(
                    file,
                    line,
                    name,
                    &target,
                    as_field.as_deref(),
                    insert_at,
                    &aggregate.value_objects,
                    &mut aggregate.attributes,
                )?;
            }
            super::PendingIdentity::Fields { line, names } => {
                let mut paths = Vec::new();
                for field in &names {
                    paths.extend(identity::resolve_identity_field(
                        file,
                        line,
                        name,
                        field,
                        &aggregate.value_objects,
                        &aggregate.attributes,
                    )?);
                }
                aggregate.identified_by = paths;
            }
            super::PendingIdentity::Inline { .. } => unreachable!(
                "inline identities are installed and converted to named identities while parsing"
            ),
        }
    }

    Ok((aggregate, policies))
}
