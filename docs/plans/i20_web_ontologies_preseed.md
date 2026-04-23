# i20 — Pre-seed Hecks domains from web ontologies (OntologyImport capability)

Source: inbox `i20` (queued, high, posted 2026-04-20) + this plan.

> **Status:** queued. Depends on nothing unshipped. Independent of i23/i27/i37
> in-flight work. First commercial lever for Embryonaut onboarding
> (pre-seeded domains). Plan-only; implementation is a multi-month arc
> broken into ~9 shippable commits.

## Summary

Today every bluebook in `hecks_conception/nursery/` is **hand-authored**.
357 domains, all written from scratch or via the `conceive` subcommand
(structural archetype interpolation from an existing corpus, no
semantic grounding).

Schema.org already encodes, for thousands of common business types,
what attributes they have, what relationships they hold, and what
actions can be taken on them. It is 15 years of curated shared
vocabulary across Google/Microsoft/Yahoo/Yandex — and a near-perfect
match for the Hecks ontology:

| schema.org | Hecks |
|---|---|
| `Type` (class) | `aggregate` |
| `Property` | `attribute` |
| `rangeIncludes: OtherType` | `reference_to(OtherType)` |
| `Enumeration` with values | attribute on a lifecycle |
| `Action` subtype | `command` |
| subtype hierarchy | (no direct equivalent; see §3) |

This plan ships `Hecks.bluebook "OntologyImport"` — a first-class
capability that fetches a schema.org definition (plus optionally
Wikidata enrichment) and emits a **nursery stub** of the corresponding
Hecks domain. The stub enters the normal nursery lifecycle: curated by
a human, then promoted out of nursery once it passes the viability
classifier (i27).

Commercial pitch: "tell us your industry, we conceive 50 domains
schema.org + Wikidata say you need". A retailer gets Product, Order,
Customer, Review, Shipment, Return as bluebooks before writing a line.

## §1 — Current state

### What exists

- **357 nursery domains**, all hand-authored. Quality ranges from
  full-workflow (bakery_production) to one-aggregate sketches.
- **`hecks-life conceive "Name" "vision"`** (621 LoC, `src/conceiver/`)
  — structural archetype interpolation. Scans the nursery corpus,
  extracts feature vectors, picks the nearest match, swaps names. It
  does NOT consult any external ontology; output semantics are random
  relative to the requested name.
- **`hecks-life heki`** subcommands (PR #272) — persistence CLI.
- **`heki_query.rs`** — shared query layer for .heki stores.
- **`rust_to_bluebook` capability** — autophagy pattern: one-way map
  from external artifact (Rust file) to bluebook. Shape reused here.
- **`adapter :shell`** (PR #251) — lets bluebooks shell out through
  declared adapters. Used for the fetch step.

### What's missing

- No path from **external ontology** → **bluebook**. Every domain
  starts from a blank page or a corpus-nearest template.
- No **UL seeding** — schema.org property labels are a rich, curated
  ubiquitous-language corpus, untapped.
- No **industry bundle** — no way to say "I'm opening a bakery, give
  me everything schema.org thinks a bakery needs" and get 8 connected
  stubs.
- No **provenance record** — once a bluebook is authored, its lineage
  (which schema.org type it came from, which version, which
  properties were kept/dropped) is lost. Matters for re-sync when
  schema.org updates.

## §2 — Source selection

### Primary: schema.org

- **Size**: ~800 types, ~30K properties, <1MB JSON-LD (single file,
  versioned).
- **License**: CC-BY-SA 3.0. Fine for attributed use; the generated
  bluebook's doc header cites schema.org as the source.
- **Freshness**: quarterly releases, stable URLs. Pinning the version
  is trivial (`--schema-version 28.0`).
- **Quality**: curated by Google/Microsoft/Yahoo/Yandex since 2011. The
  common cases (Product, Order, Person, Event, Recipe, MedicalCondition)
  are well-modeled.
- **Format**: JSON-LD graph — `@id`, `@type`, `rdfs:label`,
  `rdfs:comment`, `schema:domainIncludes`, `schema:rangeIncludes`,
  `rdfs:subClassOf`. Parseable without an RDF toolchain; plain JSON
  walk + label lookup is enough.

**Why primary**: smallest plausible corpus that already models the
80% of business nouns we care about. Single download, predictable
shape, no SPARQL endpoint to babysit.

### Secondary (optional, phase 2): Wikidata

- **Size**: ~100M items, SPARQL queryable, much deeper domain
  coverage (especially long-tail: niche industries, specific
  instruments, regional concepts).
- **Shape**: Q-IDs + properties (P31=instance of, P279=subclass of).
  Less consistent; one `Hospital` Q-item may have a dozen properties,
  another three.
- **Use**: enrichment, not primary. After a schema.org type is
  imported, optionally query Wikidata for additional example
  instances, synonyms (`aliases`), and translations (for UL i18n in
  future).

**Why secondary**: inconsistency per item + SPARQL infra cost means
it's a "go deeper" lever, not a starting point. Opt-in flag
`--enrich wikidata`.

### Rejected / deferred

- **DBpedia** — structured but stale (Wikipedia extraction lags).
  Wikidata subsumes its use cases.
- **FHIR, GS1, ISO 20022** — industry-specific. Worth importing but
  each is its own plan (vocabulary, license model, update cadence
  differ). Follow-ups: i20-follow-up/fhir, /gs1, /iso20022.
- **Common Crawl schema.org extractions** — real-world usage stats at
  scale. Useful for "which properties are *actually* used on
  Product?". Phase 3 input to prune rarely-used properties.
- **Google Product Taxonomy** — retail-specific hierarchy. Best as a
  follow-up "category bundle" plan once basic OntologyImport ships.

## §3 — Mapping table

### Schema.org → Hecks conceptual map

| schema.org construct | Hecks equivalent | Notes |
|---|---|---|
| Type (class) | aggregate | `rdfs:label` → aggregate name (CamelCase); `rdfs:comment` → aggregate description |
| Property with `schema:rangeIncludes: Text/Number/Date/Boolean` | attribute | literal type → Ruby type (Text→String, Number→Float or Integer depending on property hints, Date→String, DateTime→String, Boolean→TrueClass) |
| Property with `schema:rangeIncludes: OtherType` | reference_to(OtherType) | if OtherType is itself imported; otherwise attribute of type String (deferred import) |
| Property with multiple `rangeIncludes` | attribute typed by narrowest common ancestor, OR `list_of(ValueObject)` with tagged variants | opinionated: default to String + comment noting the variants |
| `Enumeration` type with `hasPart` values | lifecycle on an attribute | e.g. `OrderStatus` → lifecycle `on :status` with transitions; values become states |
| `Action` type (e.g. `BuyAction`, `PayAction`, `ReviewAction`) | command | Action's `object` → `reference_to`; Action's other properties → command attributes; state transition inferred from Action → Target |
| `rdfs:subClassOf` (inheritance) | **dropped** (see next row) | Hecks has no subtype mechanism |
| Subtype hierarchy (`Restaurant` < `FoodEstablishment` < `LocalBusiness` < `Organization`) | flatten to single aggregate with **inherited properties merged** | default behavior; `--flatten-ancestors 2` caps depth; provenance records which properties came from which ancestor |
| `supersededBy` | ignored for active props | edge case; log a warning in import_run |

### Concrete example: `Product` → `Product.bluebook`

schema.org gives Product these direct properties (excerpt): `name`,
`description`, `sku`, `brand`, `color`, `weight`, `offers`, `review`,
`aggregateRating`. Inherited from `Thing`: `identifier`, `image`,
`url`.

Mapping yields:

```ruby
# AUTO-GENERATED from schema.org Product (v28.0)
# Provenance: https://schema.org/Product
# Ancestors merged: Thing
# Properties dropped (see import_run): <list>

Hecks.bluebook "Product", version: "2026.04.22.1" do
  vision "A product offered for sale — schema.org:Product"
  category "retail"

  aggregate "Product", "schema:Product" do
    attribute :name, String                  # schema:name (from Thing)
    attribute :description, String           # schema:description (from Thing)
    attribute :identifier, String            # schema:identifier (from Thing)
    attribute :image_url, String             # schema:image
    attribute :url, String                   # schema:url
    attribute :sku, String                   # schema:sku
    attribute :brand, String                 # schema:brand (ref deferred)
    attribute :color, String                 # schema:color
    attribute :weight, Float                 # schema:weight

    list_of(Review) :reviews                 # schema:review
    list_of(Offer) :offers                   # schema:offers

    value_object "Review" do
      attribute :rating, Float
      attribute :author, String
      attribute :body, String
    end

    value_object "Offer" do
      attribute :price, Float
      attribute :currency, String
      attribute :availability, String
    end

    command "RegisterProduct" do
      description "schema.org BuyAction precursor — create a product"
      attribute :name, String
      attribute :sku, String
      emits "ProductRegistered"
    end

    # schema:BuyAction → BuyProduct command
    command "BuyProduct" do
      description "schema:BuyAction — purchase this product"
      reference_to(Product)
      attribute :buyer, String
      emits "ProductPurchased"
    end
  end
end
```

This is the **stub**, not the final bluebook. Curation (§6) promotes
it into a real nursery entry.

## §4 — OntologyImport capability

At `hecks_conception/capabilities/ontology_import/`. Four aggregates,
one hecksagon file for adapters, one behaviors file for assertions,
and a fixtures file for seeded config.

### Aggregates

**OntologySource** — which ontology, which version, where it lives.
Config aggregate, seeded via fixtures (like i27's ViabilityPolicy). No
user-facing commands at runtime; editing = fixture change.

```ruby
aggregate "OntologySource" do
  attribute :slug, String          # "schema_org", "wikidata"
  attribute :display_name, String  # "Schema.org", "Wikidata"
  attribute :version, String       # "28.0", "live"
  attribute :url, String           # JSON-LD download URL or SPARQL endpoint
  attribute :license, String       # "CC-BY-SA-3.0"
  attribute :flatten_ancestors, Integer, default: 3
end
```

**OntologyType** — one imported type (= one aggregate in the generated
stub). Lifecycle on `:status`: `unknown → fetched → mapped → emitted
→ curated → graduated`.

```ruby
aggregate "OntologyType" do
  attribute :source_slug, String          # FK to OntologySource
  attribute :type_name, String            # "Product"
  attribute :schema_id, String            # "https://schema.org/Product"
  attribute :description, String
  attribute :ancestors, String            # comma-separated: "Thing"
  attribute :properties_json, String      # cached JSON-LD property subset
  attribute :status, String               # lifecycle field
  attribute :nursery_path, String         # emitted bluebook path
  attribute :provenance_json, String      # which props kept/dropped/renamed

  lifecycle on: :status do
    unknown   => :fetched   via :FetchOntologyType
    fetched   => :mapped    via :MapOntologyType
    mapped    => :emitted   via :EmitNurseryStub
    emitted   => :curated   via :CurateStub
    curated   => :graduated via :GraduateStub
  end

  command "FetchOntologyType" do
    description "Pull one type's JSON-LD subgraph from the source"
    attribute :source_slug, String
    attribute :type_name, String
    emits "OntologyTypeFetched"
  end

  command "MapOntologyType" do
    description "Apply the §3 mapping table — decide attributes, refs, lifecycles, commands"
    reference_to(OntologyType)
    given { status == "fetched" }
    emits "OntologyTypeMapped"
  end

  command "EmitNurseryStub" do
    description "Write nursery/<slug>/<slug>.bluebook"
    reference_to(OntologyType)
    given { status == "mapped" }
    emits "NurseryStubEmitted"
  end

  command "CurateStub" do
    description "Human has reviewed and edited the stub"
    reference_to(OntologyType)
    given { status == "emitted" }
    emits "StubCurated"
  end

  command "GraduateStub" do
    description "Passed i27 viability; moved out of nursery"
    reference_to(OntologyType)
    given { status == "curated" }
    emits "StubGraduated"
  end
end
```

**ImportRun** — one sweep (one invocation of
`hecks-life import-schema …`). Tracks totals, duration, errors.

```ruby
aggregate "ImportRun" do
  attribute :source_slug, String
  attribute :requested_types, String       # CSV: "Product,Order,Customer"
  attribute :bundle_name, String           # optional: "retail_starter"
  attribute :started_at, String
  attribute :finished_at, String
  attribute :types_emitted, Integer
  attribute :types_skipped, Integer
  attribute :errors, String
  attribute :status, String                # "started" | "finished" | "failed"

  command "StartImport" do
    attribute :source_slug, String
    attribute :requested_types, String
    emits "ImportStarted"
  end
  command "FinishImport" do
    reference_to(ImportRun)
    attribute :types_emitted, Integer
    attribute :types_skipped, Integer
    emits "ImportFinished"
  end
  command "FailImport" do
    reference_to(ImportRun)
    attribute :errors, String
    emits "ImportFailed"
  end
end
```

**IndustryBundle** — a curated set of types ("retail_starter" =
Product+Order+Customer+Review+Shipment+Return). Config aggregate
seeded via fixtures. Commercial lever for §2 Embryonaut pitch.

```ruby
aggregate "IndustryBundle" do
  attribute :slug, String                  # "retail_starter", "restaurant_starter"
  attribute :display_name, String
  attribute :source_slug, String
  attribute :type_names, String            # CSV of schema.org types
  attribute :description, String
end
```

### Policies

- `MapAfterFetch` on `OntologyTypeFetched` → `MapOntologyType`
- `EmitAfterMap` on `OntologyTypeMapped` → `EmitNurseryStub`
- `FinishAfterAllEmitted` on `NurseryStubEmitted` → (runtime counts
  types_emitted vs requested, fires `FinishImport` when complete)
- `FailOnAnyError` on `FetchFailed|MapFailed|EmitFailed` → `FailImport`

### Hecksagon file (`ontology_import.hecksagon`)

```ruby
Hecks.hecksagon "OntologyImport" do
  adapter :memory   # runtime state is per-invocation

  adapter :shell,
          name:    :curl_schema_jsonld,
          command: "curl -fsSL {{url}}",
          ok_exit: 0

  adapter :shell,
          name:    :write_nursery_file,
          command: "mkdir -p {{dir}} && cat > {{path}}",
          ok_exit: 0

  # Wikidata SPARQL enrichment is optional phase 2
  adapter :shell,
          name:    :curl_wikidata_sparql,
          command: "curl -fsSL 'https://query.wikidata.org/sparql?query={{query}}&format=json'",
          ok_exit: 0
end
```

Fetch is a shell adapter, not an LLM adapter — it's deterministic I/O
that must not consume LLM spend.

### Fixtures

`fixtures/ontology_import.fixtures`:

- OntologySource: schema_org row (version 28.0, license CC-BY-SA-3.0,
  URL to `https://schema.org/version/latest/schemaorg-current-https.jsonld`)
- OntologySource: wikidata row (opt-in, flatten_ancestors n/a)
- IndustryBundle rows: `retail_starter`, `restaurant_starter`,
  `healthcare_starter`, `events_starter`, `media_starter`. Types
  hand-picked from schema.org docs. Opinionated; users can add their
  own via fixture edit.

## §5 — Runtime

New `hecks_life/src/run_ontology_import.rs`, registered as a subcommand
in `main.rs`:

```
hecks-life import-schema <TypeName> [--source schema_org]
                                     [--version 28.0]
                                     [--enrich wikidata]
                                     [--flatten-ancestors 2]
                                     [--out hecks_conception/nursery/<slug>/]

hecks-life import-schema --bundle retail_starter
                          [--source schema_org]
                          [--out hecks_conception/nursery/]

hecks-life ontology-import status     # list ImportRun rows
hecks-life ontology-import report     # aggregate stats
hecks-life ontology-import sync       # refresh imports whose source version bumped
```

### `import-schema <TypeName>` algorithm

1. Resolve source from OntologySource (default schema_org).
2. Load cached JSON-LD if present under `~/.cache/hecks/schema_org/<version>.jsonld`;
   else `curl_schema_jsonld`, persist.
3. Walk graph to find the requested type:
   - `@id` match on `https://schema.org/<TypeName>` or `rdfs:label` CI match.
   - Collect direct properties (`schema:domainIncludes` pointing at this type).
   - Walk `rdfs:subClassOf` up to `--flatten-ancestors` levels, merge
     ancestor properties (deduplicated by property @id).
   - Collect `Action` subtypes where `schema:target` references this type
     or an ancestor — these become commands.
4. Apply §3 mapping table. For each property:
   - Pick attribute type from rangeIncludes (literal → Ruby type; ref
     → `reference_to(OtherType)` IF OtherType is in the same import
     batch, otherwise fallback String + TODO comment).
   - Detect lifecycle candidates: if rangeIncludes is an Enumeration
     and at least 2 values, build lifecycle block.
5. Emit bluebook via template (see §5.3).
6. Append `OntologyType` record with `nursery_path`, `provenance_json`,
   status = `emitted`.
7. Append `ImportRun.FinishImport` with counts.

### `--bundle retail_starter` algorithm

1. Look up IndustryBundle by slug; get `type_names`.
2. For each type, run `import-schema` in dependency order (references
   go bottom-up: leaf types first, then types that reference them).
3. Single ImportRun aggregates all types_emitted.
4. Emit a `nursery/retail_starter/README.md` summarizing the bundle
   for human curation orientation (NOT an auto-generated `.bluebook` —
   the bundle is the *directory*, each type its own bluebook).

### `ontology-import sync` algorithm

1. For each OntologyType where `status == graduated` AND
   `source.version` differs from when it was imported:
   - Re-fetch, re-map with same flatten_ancestors.
   - Diff new properties vs recorded provenance.
   - Emit `nursery/_sync/<type>.diff` (human-readable diff, not auto-applied).
   - Mark OntologyType with `sync_diff_path`. Human reviews, hand-applies
     relevant changes. Never auto-patches graduated domains.

### Generator template (`src/run_ontology_import/template.rs`)

Renders the provenance header + aggregate block + commands. Uses
`heredoc`-style Rust string formatting (no Tera/Handlebars dependency
— Hecks is Rust-minimal, matches `rust_to_bluebook` style). Output
is **idempotent**: re-running `import-schema Product` with the same
version produces byte-identical output (stable property ordering:
alphabetical by schema.org property name).

## §6 — Post-import workflow

Import produces a stub at `hecks_conception/nursery/<slug>/<slug>.bluebook`.
Lifecycle from here:

1. **Auto-emit** — `status = emitted`. Lives in nursery. `.behaviors`
   file is a single behavioral-tests placeholder emitting one assertion
   per declared command (fails until commands are implemented).

2. **Curation** (human-in-the-loop, required). User reviews the stub:
   - Trims irrelevant attributes (schema.org tends to be wide: ~40
     properties on Product, a retailer only wants ~12).
   - Renames to local UL: schema.org's `countryOfOrigin` may become
     your `sourcing.origin_country`.
   - Adds business-specific commands/policies schema.org can't know.
   - Marks `status = curated` via
     `hecks-life heki mark … --where type_name=Product --set status=curated`.

3. **Viability gate** — run `hecks-life nursery-health scan`
   (i27). Classifier assigns Viable/Partial/Stub. Only Viable is
   eligible for graduation.

4. **Graduation** — user moves directory out of `nursery/` to a final
   location (domain-specific path in the host project). Marks
   `status = graduated`. OntologyImport records the graduation; sync
   is now opt-in only.

### Why NOT auto-promote

Schema.org is broad and shallow. A Product stub has every property a
Product *could* have — a specific retailer cares about 8 of 40. Auto-
promoting = noisy bluebooks = viability false-pass. Curation is the
value-add the human provides; the import's job is to eliminate the
blank page, not to ship the final domain.

This pairs with i27's NurseryHealth: "Stub" bucket becomes mostly
OntologyImport output pre-curation — which is fine. The classifier
distinguishes "honest stub" from "abandoned hand-sketch".

## §7 — Commit sequence (9)

1. `feat(capabilities/ontology_import): bluebook + hecksagon skeleton + fixtures`
   — aggregates OntologySource/OntologyType/ImportRun/IndustryBundle,
     lifecycle, policies, shell adapter declarations, seed fixtures
     (schema_org + wikidata + 5 industry bundles). ~200 LoC.

2. `feat(ontology_import): schema.org JSON-LD parser`
   — `src/run_ontology_import/schema_org.rs`: load+cache JSON-LD,
     resolve type by @id or label, walk subClassOf, collect properties
     + Action subtypes. Pure transform, no I/O in unit tests. ~250
     LoC + ~150 spec.

3. `feat(ontology_import): §3 mapping table implementation`
   — `src/run_ontology_import/mapping.rs`: schema property →
     Hecks attribute kind; Action subtype → command skeleton;
     Enumeration → lifecycle. Opinionated defaults. ~220 LoC + ~200
     spec covering the mapping table row-by-row.

4. `feat(ontology_import): bluebook generator template`
   — `src/run_ontology_import/template.rs`: stable ordering,
     provenance header, idempotent output. Golden-file spec against
     checked-in fixtures for Product, Person, MedicalCondition,
     Recipe, Event. ~180 LoC + ~80 spec.

5. `feat(ontology_import): hecks-life import-schema <TypeName> subcommand`
   — `src/run_ontology_import.rs`: wire parser + mapping + template +
     lifecycle-transition dispatch. Shell-adapter fetch, disk cache.
     ~200 LoC + smoke spec.

6. `feat(ontology_import): --bundle and --enrich wikidata`
   — bundle iteration (retail_starter etc.); optional Wikidata SPARQL
     enrichment (synonyms + aliases added as comments on attributes).
     ~180 LoC + specs.

7. `feat(ontology_import): status/report/sync subcommands`
   — read-only reporting over OntologyType + ImportRun; `sync`
     diff-emit workflow (no auto-patch). ~150 LoC + specs.

8. `test(ontology_import): nursery_health + parity smoke`
   — Emit Product stub, run `nursery-health scan`, assert classified
     as Stub (honest). Parity smoke: imported bluebook must parse in
     both Ruby and Rust. ~100 LoC.

9. `docs(ontology_import): FEATURES.md + docs/usage/ontology_import.md + close inbox i20`
   — Runnable examples, industry-bundle list, curation walkthrough.

**Total ~1,600 LoC.** Larger than i27 (~900 LoC) because JSON-LD
parsing + mapping table are non-trivial. Smaller than i23 (~2,600
LoC) — no dispatcher, no streaming, no provider abstraction.

## §8 — Risks

1. **Schema.org bloat** — Product has 40+ properties, most irrelevant
   to any single retailer. Mitigation: default to emitting all of
   them (user prunes in curation, not the importer). `--top-properties
   N` flag (Phase 3) uses Common Crawl usage stats to keep only the
   N most-used.

2. **Type explosion** — `--bundle healthcare_starter` could pull in
   20+ types via reference closure. Mitigation: bundles are hand-
   curated, explicit type list; reference-closure is opt-in
   `--follow-refs`. Default stays at the declared bundle.

3. **Inheritance loss** — flattening `Restaurant < FoodEstablishment
   < LocalBusiness < Organization` into one aggregate loses the class
   hierarchy. Mitigation: provenance header records ancestry; `--flatten-
   ancestors N` knob. This is an honest modeling difference — Hecks
   has no subtypes, and trying to fake them would confuse the
   runtime. Document clearly.

4. **Stale imports** — schema.org bumps versions; imported stubs
   don't auto-update. Mitigation: `sync` subcommand emits diffs,
   never auto-applies. Graduated domains are owned by the user.

5. **License contamination** — CC-BY-SA 3.0 requires attribution and
   share-alike. Mitigation: auto-emitted provenance header cites the
   source and version; docs/usage/ontology_import.md covers the
   share-alike implication (if you redistribute the bluebook, the
   doc comment is the attribution). For MIT-licensed Hecks projects
   this is a non-issue at the tool level — the generated bluebook
   is the user's derivative work.

6. **Wikidata rate limits** — SPARQL endpoint has a 60 req/min ceiling.
   Mitigation: `--enrich wikidata` is opt-in; enrichment is batched
   per ImportRun; 429 fails the ImportRun gracefully with partial
   results recorded.

7. **Mapping opinions baked in** — §3 "Property with multiple
   rangeIncludes → String with variant comment" is a judgment call.
   Mitigation: opinionated defaults, `--strict-types` flag to fail
   instead. Re-running with different flags is cheap (idempotent
   regeneration).

8. **Ruby DSL gap** — same i1/i2 concern as other capabilities;
   `adapter :shell` already in Ruby (PR #251), no new DSL primitives
   here. Emitted bluebooks are standard DSL, parse in both runtimes.

9. **Commercial positioning vs. open source** — "pre-seeded
   onboarding" is an Embryonaut pitch; the capability is in
   open-source Hecks. Both can be true: open capability, commercial
   curation-as-a-service + SME curation layers on top. Noted here,
   decision deferred to Embryonaut thread.

## §9 — Out of scope

- **LLM-assisted curation** — "summarize what a user *probably*
  wants from this Product stub". Phase 3. Hooks into i23 `adapter
  :llm` once it ships.
- **Bi-directional sync** — emitting schema.org JSON-LD *back out*
  from a Hecks domain (for SEO/semantic markup). Interesting, own
  plan.
- **Non-schema.org primary** — FHIR / GS1 / ISO 20022 are each their
  own importer (different parse, different mapping table, different
  license). One plan each, all following this capability pattern.
- **Live ontology browsing** — a "schema.org browser" REPL UI. Nice-
  to-have, own plan.
- **Multi-language UL** — Wikidata `aliases` give us translations.
  Phase 3 once Hecks has i18n in UL.

## Key files

### New
- `hecks_conception/capabilities/ontology_import/ontology_import.bluebook`
- `hecks_conception/capabilities/ontology_import/ontology_import.behaviors`
- `hecks_conception/capabilities/ontology_import/ontology_import.hecksagon`
- `hecks_conception/capabilities/ontology_import/fixtures/ontology_import.fixtures`
- `hecks_life/src/run_ontology_import.rs`
- `hecks_life/src/run_ontology_import/schema_org.rs`
- `hecks_life/src/run_ontology_import/mapping.rs`
- `hecks_life/src/run_ontology_import/template.rs`
- `hecks_life/tests/ontology_import_smoke.rs`
- `hecks_life/tests/fixtures/schema_org_mini.jsonld` (curated subset for tests)
- `hecks_life/tests/golden/product.bluebook` + `person.bluebook` + etc.
- `docs/usage/ontology_import.md`

### Modified
- `hecks_life/src/main.rs` — register `import-schema` / `ontology-import` subcommands
- `FEATURES.md` — new capability entry
- `docs/plans/INDEX.md` — add i20 row

### Reused
- `hecks_life/src/heki.rs`, `heki_query.rs` — persistence + query
- `hecks_life/src/parser.rs` — parse emitted bluebook to validate
- `hecks_conception/capabilities/nursery_health/` — downstream viability gate (i27)
- `hecks_conception/capabilities/antibody/antibody.hecksagon` — shape reference for hecksagon file
- `hecks_conception/capabilities/rust_to_bluebook/` — shape reference for autophagy-style lifecycle

## Dependencies

**None unshipped.** schema.org JSON-LD is a stable public URL.
`adapter :shell` is already in Ruby (PR #251) and Rust. `heki`
subcommands are in (PR #272). i27 NurseryHealth is a downstream
consumer — helpful but not required for i20 to ship.

## Relationship to other in-flight plans

- **i27 NurseryHealth** — classifier downstream of OntologyImport.
  Imported stubs will classify as Stub until curated. Expected.
- **i23 LLM adapter** — OntologyImport does NOT use the LLM adapter.
  Fetch is shell, mapping is deterministic. A Phase 3 follow-up
  (LLM-assisted pruning / UL renaming) WOULD depend on i23.
- **i37 Python removal** — no overlap. OntologyImport is Rust-native.
- **i1/i2 Ruby DSL gap** — generated bluebooks use only DSL primitives
  already in both runtimes (`attribute`, `reference_to`, `list_of`,
  `value_object`, `lifecycle`, `command`, `emits`). Expected
  parity-clean.
- **Embryonaut** — commercial pitch ("pre-seeded onboarding") depends
  on this capability landing. Industry bundles are the retail-facing
  knob. Not a blocker in either direction; open-source Hecks ships
  the capability, Embryonaut layers curation-as-a-service on top.

## Inbox update

After plan merges, update inbox.heki i20 body to reference this plan
path:

```
hecks-life heki mark hecks_conception/information/inbox.heki \
  --where ref=i20 \
  --set body="<updated body with plan link to docs/plans/i20_web_ontologies_preseed.md>" \
  --set updated_at=<iso>
```

Status stays `queued` until implementation PR 1 lands.
