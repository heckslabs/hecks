# i42 — Catalog-dialect: retire shape-only aggregates

Source: inbox `i42` + plan by planning agent on 2026-04-22.

## 1. Current state (why the transitional pattern is wrong)

PR #267 landed four shape-only aggregates in
`hecks_conception/capabilities/antibody/antibody.bluebook` lines 217-244:

- `FlaggedExtension` — one `:ext, String` attribute. No commands, no
  lifecycle, no policies.
- `ShebangMapping` — `:match, :ext`. Same.
- `ExemptionPattern` — `:pattern, :flags, :anchor`. Same.
- `TestCase` — `:touched_files, :message, :expected`. Same.

Each exists purely so the rows in
`hecks_conception/capabilities/antibody/fixtures/antibody.fixtures`
resolve against a declared schema. PR #258's orphan inventory flagged
them as "all refs orphan"; PR #267 silenced the audit by declaring
the schemas as aggregates.

This is a DDD smell in three ways:

1. **Aggregates without commands aren't aggregates.** A DDD aggregate
   is a consistency boundary around state-mutating behavior. These
   four have no state mutations — their "state" is loaded once from
   fixtures and never changes.
2. **The orphan audit got satisfied, not solved.** The audit ensures
   every fixture row has a declared schema. Shape-only aggregates
   satisfy that check mechanically but re-introduce the rule they
   violate: every declared aggregate should have behavior.
3. **Downstream generators will hallucinate behavior.** The Go/Ruby
   codegens emit CRUD scaffolding for every aggregate. Shape-only
   aggregates will produce `CreateTestCase`, `UpdateFlaggedExtension`,
   etc. — noise that nobody will ever call.

The real fix is a first-class DSL form for **fixture-only reference
tables that self-declare their row schema** — a "catalog" is not an
aggregate, it's a lookup table with a shape.

## 2. Syntax shape

**Chosen: Option B — extend `.fixtures` with a `schema:` kwarg on
`aggregate`.**

```ruby
Hecks.fixtures "Antibody" do
  aggregate "FlaggedExtension", schema: { ext: String } do
    fixture "Ruby", ext: "rb"
    fixture "Rust", ext: "rs"
  end

  aggregate "ShebangMapping", schema: { match: String, ext: String } do
    fixture "Ruby", match: "ruby", ext: "rb"
  end
end
```

The `schema:` kwarg, when present, signals: "this aggregate is a
catalog — no bluebook declaration required, the schema here is
authoritative." Absence preserves today's behavior.

### Why Option B over Option A (`Hecks.catalog`)

**Option A surface area:**
- New top-level DSL keyword (`Hecks.catalog`).
- New registry slot (`Hecks.last_catalog_file`).
- Potentially new file extension (`.catalog`).
- New Rust parser entry point + `CatalogFile` IR.
- New parity contract, new parity test harness, new `dump-catalog` CLI.

**Option B additions:**
- A third argument path in `FixturesBuilder#aggregate` (kwarg).
- A `schema` field on `FixturesFile` — serialized by existing `dump-fixtures`.
- A parse-line extension in `fixtures_parser.rs`.

**Migration friction.** Option A forces file renames
(`antibody.fixtures` → `antibody.catalog`) + path updates in every
loader. Option B is a pure in-file edit.

**Decision: Option B.** Option A is worth revisiting if we grow a
*third* kind of self-declaring catalog (enum tables, constant packs),
but for the i42 case, Option B covers it with ~5x less plumbing.

## 3. Parser work

### 3.1 Ruby DSL (`lib/hecks/dsl/fixtures_builder.rb`)

```ruby
def aggregate(name, schema: nil, &block)
  @current_aggregate = name.to_s
  @schemas[@current_aggregate] = normalize_schema(schema) if schema
  instance_eval(&block) if block
  @current_aggregate = nil
end

private

def normalize_schema(schema)
  schema.map { |k, v| { name: k.to_s, type: v.to_s } }
end
```

`FixturesFile` grows a `catalogs` field:

```ruby
class FixturesFile
  attr_reader :name, :fixtures, :catalogs
  def initialize(name:, fixtures: [], catalogs: {})
    @name = name
    @fixtures = fixtures
    @catalogs = catalogs
  end
end
```

### 3.2 Rust parser (`hecks_life/src/fixtures_parser.rs`)

```rust
} else if line.starts_with("aggregate ") && ends_with_do_block(line) {
    current_agg = extract_string(line);
    if let Some(schema) = extract_schema_kwarg(line) {
        file.catalogs.insert(current_agg.clone().unwrap(), schema);
    }
    depth += 1;
}
```

`FixturesFile` grows:

```rust
pub struct FixturesFile {
    pub domain_name: String,
    pub fixtures: Vec<Fixture>,
    pub catalogs: BTreeMap<String, Vec<CatalogAttr>>,
}

pub struct CatalogAttr {
    pub name: String,
    pub type_name: String,
}
```

### 3.3 Parity constraints

Both parsers must produce structurally identical output. Extend
`spec/parity/fixtures_parity_test.rb` to compare `catalogs` maps.
Drift on either side is a hard fail.

## 4. Runtime — catalogs stay catalogs

**Chosen: catalogs are NOT hoisted into the aggregate registry.**

The alternative — "hoist a catalog's schema into the aggregate
registry as a synthetic aggregate" — re-creates the problem we're
solving. Codegen would generate CRUD, validator would emit events,
etc.

What *does* happen at runtime:

- **`FixturesLoader#apply`**: if `fixtures_file.catalogs[agg_name]`
  declares a schema, synthesise a lightweight read-only "catalog
  repository" and seed rows into it. Keyed access works, commands
  do not.
- **Bluebook registry** (`Hecks.loaded_bluebooks`) does NOT grow
  entries for catalogs.
- **Codegen** ignores catalogs entirely.
- **Validator**: new rule handles catalog schema vs row validation.

**Runtime API:**
- `rt.catalogs[name]` returns `Hash<label, AggregateState>` (read-only)
- `rt.repositories[name]` remains aggregate-only (separate slot
  prevents accidental writes)

## 5. Consumer audit — what reverts

### 5.1 The 4 shape-only aggregates (delete)

`hecks_conception/capabilities/antibody/antibody.bluebook` lines 204-244:
- `FlaggedExtension` aggregate
- `ShebangMapping` aggregate
- `ExemptionPattern` aggregate
- `TestCase` aggregate
- Enclosing "CONFIG CATALOGS" comment block

Net deletion: ~42 lines.

### 5.2 The fixtures file (extend)

`hecks_conception/capabilities/antibody/fixtures/antibody.fixtures` —
each `aggregate "X" do` grows a `schema:` kwarg:

```ruby
aggregate "FlaggedExtension", schema: { ext: String } do
aggregate "ShebangMapping",   schema: { match: String, ext: String } do
aggregate "ExemptionPattern", schema: { pattern: String, flags: String, anchor: String } do
aggregate "TestCase",         schema: { touched_files: list_of(String),
                                        message: String,
                                        expected: String } do
```

Net addition: ~4 lines.

### 5.3 Rust antibody shim

No existing consumer. When it lands, it reads catalogs via
`runtime.catalogs["FlaggedExtension"]`.

### 5.4 Behaviors file (unchanged)

Zero changes — antibody tests target CommitCheck, BranchScan,
StagedCheck, not the catalog aggregates.

## 6. Parity coverage

Add `spec/parity/fixtures/catalog_basic.fixtures`:

```ruby
Hecks.fixtures "CatalogParitySuite" do
  aggregate "Color", schema: { hex: String, name: String } do
    fixture "Red",   hex: "#FF0000", name: "Red"
    fixture "Green", hex: "#00FF00", name: "Green"
  end
end
```

And `spec/parity/fixtures/catalog_edge_cases.fixtures`:
- Single-row catalog
- Schema with `list_of(String)`
- Catalog + plain aggregate in one file

Extend `spec/parity/fixtures_parity_test.rb` to compare `catalogs` maps.
Zero drift is the acceptance bar.

## 7. Orphan audit update

Add `lib/hecks/validation_rules/structure/fixture_aggregate_refs.rb`:

```ruby
class FixtureAggregateRefs < BaseRule
  def errors
    result = []
    fixtures_file = find_fixtures_for(@domain)
    return result unless fixtures_file

    fixtures_file.fixtures.each do |fix|
      next if aggregate_declared?(@domain, fix.aggregate_name)
      next if catalog_declared?(fixtures_file, fix.aggregate_name)
      result << "Fixture '#{fix.name}' references aggregate " \
                "'#{fix.aggregate_name}' which is neither declared in " \
                "the bluebook nor as a catalog schema."
    end
    result
  end
end
```

Companion `CatalogSchemaCoverage` rule verifies every row supplies
every declared schema attribute.

## 8. Commit sequence + LoC estimate

1. `feat(fixtures-ir): FixturesFile.catalogs + CatalogAttr` — ~40 LoC
2. `feat(fixtures-builder): schema: kwarg on aggregate (Ruby)` — ~25 LoC
3. `feat(fixtures-parser): parse schema: kwarg (Rust)` — ~60 LoC
4. `feat(dump-fixtures): emit catalogs in JSON` — ~15 LoC
5. `test(parity): catalog_basic + catalog_edge_cases fixtures` — ~45 LoC
6. `feat(fixtures-loader): read-only catalog repos` — ~40 LoC
7. `feat(validation): FixtureAggregateRefs + CatalogSchemaCoverage` — ~60 LoC
8. `refactor(antibody.fixtures): add schema: to 4 aggregates` — ~10 LoC
9. `refactor(antibody.bluebook): delete 4 shape-only aggregates` — ~42 LoC removed
10. `docs(orphan-inventory): regenerate — zero orphans` — ~15 LoC
11. `test(antibody.behaviors): spot-check catalog accessible` — ~20 LoC
12. `docs(plans): close i42; inbox mark done` — ~5 LoC

**Total: ~300 LoC added, ~60 LoC deleted (net ~+240 LoC).**

## 9. Risks

### 9.1 Parser ambiguity on `schema:` kwarg

Line-based `starts_with` scanner breaks on multi-line schema.
*Mitigation*: constrain to single-line schema in v1. Multi-line is v2.

### 9.2 `list_of(Type)` inside schema

Parentheses inside the `{ ... }` confuse comma-splitting.
*Mitigation*: reuse `split_top_level_commas`. Add unit test.

### 9.3 Backward compat with existing 356 `.fixtures` files

`schema: nil` default + conditional Rust parsing guarantees no
breakage.
*Mitigation*: CI runs full parity suite; zero drift is the bar.

### 9.4 Codegen hallucinating catalogs as aggregates

Future refactor might try to unify aggregates and catalogs.
*Mitigation*: runtime separation (`rt.repositories` vs `rt.catalogs`)
is a deliberate fence. Document it.

### 9.5 Runtime catalog API not load-bearing yet

Antibody has no Rust shim today. We might under-specify the read API.
*Mitigation*: implement minimum viable API
(`rt.catalogs[name]`). Ship shim in a follow-up.

### 9.6 BTreeMap ordering

Rust BTreeMap preserves iteration order; Ruby Hash is
insertion-ordered.
*Mitigation*: sort by aggregate name before serialization in the
parity harness.

## Key answers

- **New file extension needed?** No. `.fixtures` + `schema:` kwarg.
- **Catalogs register as aggregates at runtime?** No. Separate slot.
- **Existing `.fixtures` usage changes?** No — `schema:` is opt-in.
- **When does runtime read a catalog?** Only when code asks
  (`rt.catalogs["FlaggedExtension"]`). Today nothing asks — antibody's
  Rust shim is the first intended consumer (deferred).

### Critical Files for Implementation

- `lib/hecks/dsl/fixtures_builder.rb`
- `hecks_life/src/fixtures_parser.rs`
- `hecks_life/src/fixtures_ir.rs`
- `lib/hecks/behaviors/fixtures_loader.rb`
- `hecks_conception/capabilities/antibody/antibody.bluebook`
