# PLAN — JSON Schema projection : the published language of validation

**Decided with Chris, 2026-07-18 (workshop-demo session).**
**One sentence : project standard JSON Schema (draft 2020-12) per command/query from the IR, so the whole ecosystem builds our validators for us — while the payload gate remains the law.**

## What exists / what doesn't (verified 2026-07-18)
- HAVE : `storehouse__catalog` / `describe_aggregate` emit the full IR as JSON — attributes, VO shapes, required flags, invariant text. The raw material is complete.
- HAVE NOT : no standard JSON Schema emission anywhere (grep: no inputSchema/json_schema generation in rust/ ; `projection/` holds only terraform ; the MCP dispatch tool carries ONE generic hand-written schema, not per-command schemas).

## Why standard JSON Schema (not just our IR JSON)
JSON Schema is the ecosystem's published language for payload validity. Emitting it buys, without writing their code :
- browser pre-flight (ajv) — instant field-level feedback, zero hand-written form JS
- third-party clients validating BEFORE they call us
- MCP door declaring real per-command `inputSchema`s (today : one generic dispatch shape)
- `/openapi.json` off the serve door → instant client/SDK generation
- LLM structured-output modes fed directly from domain law

## The mapping (deterministic, thin, over existing IR)
| Bluebook IR | JSON Schema |
|---|---|
| command attributes | `properties` |
| attr without default | `required` |
| wrapper VO (single inner scalar) | unwrapped `type` (same rule as the form renderer) |
| multi-attribute VO | object in `$defs`, `$ref`'d |
| `reference_to X` | string prop + description "id of X" |
| stray-key law | `additionalProperties: false` |
| `one_of("USD","CAD")` (when it lands — see GRAMMAR-one-of card) | `enum` |
| `one_of do member … end` | `enum` over discriminants + member table in `$defs` |
| `invariant { cents >= 0 }` | `minimum: 0` — many invariants ARE schema keywords (>=, <=, size, simple comparisons) |
| invariant beyond schema's power | `x-hecks-invariant: "<name>"` annotation — carried, not enforced by schema |

## The ruling that keeps it honest
Schema is the PORTABLE PROJECTION of the law, never the law. The payload gate (PLAN-payload-gate-acl.md) is the single enforcement point and runs EVERYTHING, including invariants schema cannot express. Outer rings (browser, clients, MCP) use schema for courtesy + early feedback ; the gate rules. No drift possible : both are read from the same IR, neither is hand-written.

## Surface
- `storehouse schema <root> [Domain::Aggregate.Command]` — print one schema (or all, keyed by FQN)
- served : `GET /domains/{d}/schema` (all) and per-command — hot-reloads with the bluebook like everything else
- MCP : catalog gains per-command inputSchema derivation (later phase)

## Implementation sketch
1. `src/projection/json_schema.rs` (new, 200-line rule) : walk Domain → per command/query emit schema via the mapping table. Reuse the wrapper-unwrap logic the form renderer uses (extract shared helper rather than duplicating the heuristic).
2. CLI arm `schema` + routes.rs GET handler.
3. Tests : golden schemas for Pizzas (PlaceOrder with reference + VO + invariant→minimum) and ToolShed ; assert `additionalProperties:false` everywhere ; assert unmappable invariant surfaces as x-hecks-invariant.
4. Ruby side : none required initially (projection is a Rust kernel emission) ; if parity wants it, dump comparison comes later.

## Compounding note
Every grammar word enriches this projection automatically — `one_of` lands → every schema grows enums → every dropdown/client/LLM tightens, from one bluebook line. The language is the product.

## Cross-refs
- PLAN-payload-gate-acl.md — the law this projects
- GRAMMAR-one-of-closed-value-sets.md — the enum source
