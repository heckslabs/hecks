require "json"
require "open3"
require "hecks/fuzzing"
require_relative "../support/rust_conformance_helpers"

# BUG#25 — THE REGRESSION PROOF. `qa/stress_domains/referral_chain`'s
# first draft (PR #580) found that a `has_many` field (a LIST OF
# REFERENCES, never before exercised anywhere in the corpus) emitted a
# Rust module that did not compile — `&String` has no `.to_json()`; a
# fabricated, never-generated `ReferenceMember::from_json`; the scalar
# `.value` collapse applied to a `Vec` — and because `rust/src/
# generated/mod.rs` declared every domain with an unconditional `pub
# mod`, that one broken module broke `cargo build --features <any
# other domain>` too.
#
# `spec/fixtures/rust_project/has_many_fixture` is the minimal domain
# that reaches every one of those three sites at once: `Circle` declares
# `has_many Members`, and its own `Admit` command `sets :members` from a
# `list_of(Handle)` argument — exactly PR #580's own removed `Circle`
# (`Admit` "supplying the list under `list_of(Handle)`", per that PR's
# body and `qa/stress_domains/referral_chain/NOTES.md`, finding 1).
#
# `io: true` — a real `cargo build` (and, below, a real compiled-binary
# subprocess), same convention as every other spec in this file's own
# family (`rust_conformance_spec.rb`, `domain_feature_exclusivity_spec.
# rb`).
RSpec.describe "has_many — Rust codegen compiles and round-trips (BUG#25)", :io do
  include RustConformanceHelpers

  # `HAS_MANY_` PREFIXED, NOT BARE — `spec/load_hygiene_spec.rb` refuses
  # two spec files sharing a top-level constant name (a bare `RUST_DIR`
  # already belongs to `rust_conformance_spec.rb`, a bare `STEPS` to
  # `self_consistency_spec.rb`); same reason `domain_feature_exclusivity_
  # spec.rb` scopes its own to `DFE_RUST_DIR` rather than a bare
  # `RUST_DIR`.
  FIXTURE_DOMAIN = "spec/fixtures/rust_project/has_many_fixture".freeze
  HAS_MANY_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")
  GENERATED_CIRCLE = File.join(HAS_MANY_RUST_DIR, "src/generated/has_many_fixture/circle.rs")

  def build_rust_for(domain_feature) = super(domain_feature, HAS_MANY_RUST_DIR)

  # THE HAPPY-PATH SEQUENCE — two members join, a circle opens, then
  # `Admit` sets its whole `has_many` list in one `sets :members`, the
  # exact shape BUG#25 is about. Every member handle admitted is a real,
  # already-`Join`ed one (`resolve_state_references`'s own LIST branch,
  # `lib/hecks/runtime/command_rules/references.rb`, checks each element
  # exists), so this sequence refuses nothing on either engine.
  HAS_MANY_STEPS = [
    { "verb" => "HasManyFixture::Member.Join", "args" => { "handle" => { "value" => "alice" } } },
    { "verb" => "HasManyFixture::Member.Join", "args" => { "handle" => { "value" => "bob" } } },
    { "verb" => "HasManyFixture::Circle.Open", "args" => { "id" => { "value" => "c1" } } },
    { "verb" => "HasManyFixture::Circle.Admit",
      "args" => { "id" => { "value" => "c1" }, "members" => [{ "value" => "alice" }, { "value" => "bob" }] } }
  ].freeze

  it "bin/project_rust's own generated circle.rs no longer collapses the has_many list with the scalar .value fallback" do
    # Pinned directly against the generated SOURCE TEXT, not just runtime
    # behavior — this is the literal line BUG#25's own demonstration
    # named as broken (`record.members = args.members.value.clone()`,
    # the scalar single-field-VO unwrap applied to a whole `Vec`). If
    # `bin/project_rust spec/fixtures/rust_project/has_many_fixture` is
    # ever re-run and this regresses, this line fails before any cargo
    # build even has to.
    source = File.read(GENERATED_CIRCLE)
    expect(source).to include("record.members = args.members.iter().map(|item| item.value.clone()).collect();")
    expect(source).not_to include(".value.clone();\n") # the old, bare (non-per-element) collapse
    expect(source).not_to include("ReferenceMember::from_json")
  end

  it "the generated has_many_fixture module actually compiles" do
    binary = build_rust_for("has_many_fixture")
    expect(binary).not_to be_nil, "cargo build --features has_many_fixture failed — run bin/project_rust " \
                                  "spec/fixtures/rust_project/has_many_fixture first if rust/Cargo.toml has no such feature"
  end

  it "a real command sequence round-trips through the compiled binary: has_many's own list serializes as bare " \
     "reference strings, never nested value objects" do
    binary = build_rust_for("has_many_fixture")
    skip "rust/Cargo.toml has no has_many_fixture feature — run bin/project_rust for it first" unless binary

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => HAS_MANY_STEPS }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

    rust_output = JSON.parse(stdout)
    expect(rust_output["refusals"]).to eq([])

    circle = rust_output["instances"]["HasManyFixture::Circle#c1"]
    # THE HEART OF THE FIX — a `Reference<Member>` list stores bare ids,
    # the same convention every OTHER reference already gets
    # (`naming.rb`'s own `reference_type?` header: "a reference is a
    # bare id — a String — not a nested object"), never
    # `{"value": "alice"}`-shaped Handle objects.
    expect(circle["members"]).to eq(%w[alice bob])

    # THE JSON ROUND-TRIP ITSELF — `to_json` (the "state" mutation log
    # entry) and `from_json` (what built THAT SAME instance back for the
    # very next dispatch's own hydrate step, two steps later in the SAME
    # process) already agree with each other by construction: every
    # later read of `HasManyFixture::Circle#c1` in this one run came
    # back through the fixed `from_json` list branch, and every write
    # went through the fixed `to_json` one — a shape mismatch in EITHER
    # direction would have surfaced as a `TypeMismatch` refusal above,
    # not a silently wrong answer.
    expect(rust_output["mutations"].last.first["state"]["members"]).to eq(%w[alice bob])
  end

  it "Ruby and Rust agree on every step that does not touch the has_many list itself (Member.Join, Circle.Open)" do
    binary = build_rust_for("has_many_fixture")
    skip "rust/Cargo.toml has no has_many_fixture feature — run bin/project_rust for it first" unless binary

    non_list_steps = HAS_MANY_STEPS.first(3) # both Joins + Open — no has_many field touched yet
    ruby_result = Hecks::Fuzzing::Replay.call(FIXTURE_DOMAIN, non_list_steps)
    ruby_instances = JSON.parse(JSON.generate(ruby_result[:instances]))
    ruby_events = JSON.parse(JSON.generate(ruby_result[:events]))

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => non_list_steps }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"
    rust_output = JSON.parse(stdout)
    strip_occurred_at!(rust_output["events"])

    expect(rust_output["instances"]).to eq(ruby_instances)
    expect(rust_output["events"]).to eq(ruby_events)
    expect(rust_output["refusals"]).to eq([])
  end

  # NOT a byte-for-byte parity claim on the `members` field itself — a
  # REAL, SEPARATE, PRE-EXISTING gap this fixture found live and outside
  # BUG#25's own scope (a Rust codegen bug, `rust/project/*.rb` and
  # `rust/codegen/src/*.rs` only): `Runtime::Value::Coercion#
  # reference_list` (`lib/hecks/runtime/value/coercion.rb`) freezes a
  # `:set` mutation's whole source Array as-is (`Freezer.deep(value.
  # dup)`) rather than collapsing each element into its own bare
  # reference identity the way `reference_identity` already does for a
  # SCALAR reference — so Ruby's own stored `members` field holds the
  # ORIGINAL `Handle` value objects (`[{"value":"alice"}, ...]`), not
  # bare ids, even though `naming.rb`'s own documented convention (and
  # this fix's own Rust output, proven above) says a reference is always
  # a bare id. Normalized away here (collapsing each Ruby element down
  # to its own sole field) so this example proves what IS in scope —
  # Ruby and Rust agree on which members got admitted, in order — without
  # silently asserting a byte-for-byte shape match neither this PR nor
  # BUG#25 claims to fix. Left for a future bug/session, same as PR
  # #580's own findings 2-4.
  it "Ruby and Rust agree on WHICH members got admitted, modulo Ruby's own separate reference_list shape gap" do
    binary = build_rust_for("has_many_fixture")
    skip "rust/Cargo.toml has no has_many_fixture feature — run bin/project_rust for it first" unless binary

    ruby_result = Hecks::Fuzzing::Replay.call(FIXTURE_DOMAIN, HAS_MANY_STEPS)
    ruby_instances = JSON.parse(JSON.generate(ruby_result[:instances]))
    ruby_members = ruby_instances.fetch("HasManyFixture::Circle#c1").fetch("members")
    ruby_member_ids = ruby_members.map { |m| m.is_a?(Hash) ? m.fetch("value") : m }
    expect(ruby_result[:refusals]).to eq([])

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => HAS_MANY_STEPS }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"
    rust_output = JSON.parse(stdout)

    expect(rust_output["instances"]["HasManyFixture::Circle#c1"]["members"]).to eq(ruby_member_ids)
  end
end
