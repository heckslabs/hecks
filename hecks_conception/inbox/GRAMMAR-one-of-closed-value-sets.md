# GRAMMAR — `one_of` : closed value sets (aggregate-local, whole-value members)

**Designed with Chris, 2026-07-18 (currency conversation). Companion to PLAN-payload-gate-acl (enforcement) and PLAN-json-schema-projection (enum emission).**

## The ruling (Chris, explicit)
**NO global type registry.** Value objects stay INSIDE the aggregate ; duplication across aggregates is fine — it is sovereignty, not debt (Tool's Price and Loan's Price may legitimately diverge : different currency vocabularies, different caps). The locked VO-placement convention (i555) stands. A `.type` framework artifact was considered and REJECTED — the admissibility test ("could two customers want this type to differ?") fails even for Currency.

## One concept, two spellings
A closed set of WHOLE VALUES. Membership = value equality (works because VOs have value semantics — Evans : equal when attributes are equal ; no identity, no lifecycle).

**Scalar sugar** (attribute site) :
```ruby
attribute :standing, one_of("good", "suspended", "banned"), default: "good"
```

**Whole-value members** (the VO itself is closed) :
```ruby
value_object "Currency" do
  attribute :code,        String
  attribute :symbol,      String
  attribute :minor_units, Integer
  one_of do
    member code: "USD", symbol: "$",  minor_units: 2
    member code: "CAD", symbol: "C$", minor_units: 2
    member code: "JPY", symbol: "¥",  minor_units: 0
  end
end
```
Scalar form ≡ anonymous single-attribute VO with members. Closed-ness is a property of the TYPE ; every reference inherits it.

## Semantics
- **Discriminant** : first attribute keys the member (form submits "USD") ; the gate resolves the WHOLE member — the domain receives symbol + minor_units without any lookup service. The lookup table lives in the type.
- **Storage** : persist the discriminant only ; hydrate the member from IR on read. If members change in the bluebook, the retro-audit sweep (gate card follow-on) names violations.
- **VO composition** : `attribute :currency, Currency` inside another local VO (Price) — refer-by-name within the aggregate. Parser likely tolerates this today (types are strings) but tolerated ≠ modeled : verify + pin in BOTH parsers + parity.
- **Category boundary the grammar now teaches** : closed set of VALUES → one_of → dropdown. Open set of ENTITIES → reference_to → record browser. `one_of` over an entity is unspellable — identity things are referenced, never enumerated.

## Projections (all free, all from IR)
- form : dropdown ($ USD / C$ CAD / ¥ JPY) — replaces the hand-painted enum dropdowns in html_wizard.rs fieldInput (power_type, chemistry …) which should RETIRE onto this
- gate : membership check at construction, field-targeted refusal
- record chip : symbol-aware display (¥1200 — minor_units 0 kills a whole class of rounding bugs)
- json schema : enum over discriminants + member table in $defs

## Canonical exemplars (extend Pizzas per standing rule)
```ruby
value_object "Size" do
  attribute :name,           String
  attribute :inches,         Integer
  attribute :price_modifier, Integer
  one_of do
    member name: "small",  inches: 10, price_modifier: 0
    member name: "medium", inches: 12, price_modifier: 300
    member name: "large",  inches: 14, price_modifier: 600
  end
end
```
Plus ToolShed : Currency/Price (above), Member.Standing (scalar sugar).

## Lineage (for the vision block when this becomes grammar)
Evans : Whole Value (via Cunningham CHECKS) — the type's universe IS the legal set, illegal values unconstructible. Making Implicit Concepts Explicit — the vocabulary is a named domain concept in the ubiquitous language. Published Language — for world-owned sets (ISO-4217) bind to the standard. Specification — the ladder up when membership grows into logic. Fowler : Money. CHECKS pairs Instant Reaction (dropdown) with Deferred Validation (gate).

## LANDED — 2026-07-19, same session, all gates green
- Both spellings live : scalar sugar (`one_of("good","suspended")` → attribute vocabulary) + whole-value members (`one_of do member … end` → VO members, first attribute = discriminant). Both parsers, byte-equal.
- Gate membership bites : `must be one of: USD, CAD, JPY — currency = EUR` refused at every door.
- Form renders dropdowns : scalar values plain ; members labeled with every field joined " · " (USD · $ · 2).
- Canonical IR keys : `one_of` (attribute) + `members` (VO) — named as WORDS ("enum is too codey" — Chris, mid-implementation ruling).
- **The legacy `enum:` kwarg is RETIRED** : all 20 hecks-side + 27 miette-side files migrated to one_of the same day. The Rust parser deliberately does NOT read `enum:` — the Ruby side still collects it, so any straggler drifts loudly in parity. The ledger is the guard.
- Validator : one_of scalars exempt from primitive-envy (the vocabulary IS the type).
- En route the canonical field exposed a latent 20-file parser drift (Ruby collected `enum:`, Rust ignored it) — same class as the dropped VO invariants, now structurally impossible to reintroduce.
- Parity 388/388 (fixture 25 proves both spellings) ; behaviors 779/779 ; workspace clean ; zero warnings.
- Deferred (still open here) : hand-painted wizard enum dropdowns (power_type, chemistry …) retire onto one_of ; Pizzas Size canonical exemplar rides the next Pizzas-canon pass ; JSON Schema enum emission rides PLAN-json-schema-projection.

## Touch list (original, for reference)
- Ruby DSL : `one_of(*values)` attribute type + `one_of do member … end` VO block
- Rust parser : same two forms → IR (new enum-carrying attr_type or VO.members)
- IR + dump.rs + canonical_ir.rb (parity — note aggregate identified_by parity gap discovered same session)
- gate : membership enforcement (rides PLAN-payload-gate-acl)
- form renderer : dropdown from IR ; retire hand-coded fieldInput enums
- schema projection : enum emission (rides PLAN-json-schema-projection)
