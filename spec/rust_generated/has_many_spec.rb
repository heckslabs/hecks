require "json"
require "open3"
require "hecks/fuzzing"
require_relative "../support/rust_conformance_helpers"

# A has_many field (a list of references) must generate Rust that compiles and round-trips.
# The fixture's `Circle` has_many Members, and its `Admit` sets :members from list_of(Handle).
# `io: true` -- a real `cargo build` and a compiled-binary subprocess.
RSpec.describe "has_many — Rust codegen compiles and round-trips (BUG#25)", :io do
  include RustConformanceHelpers

  # HAS_MANY_ prefix: spec/load_hygiene_spec.rb refuses spec files sharing a top-level constant.
  FIXTURE_DOMAIN = "spec/fixtures/rust_project/has_many_fixture".freeze
  HAS_MANY_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")
  GENERATED_CIRCLE = File.join(HAS_MANY_RUST_DIR, "src/generated/has_many_fixture/circle.rs")

  def build_rust_for(domain_feature) = super(domain_feature, HAS_MANY_RUST_DIR)

  # Two members join, a circle opens, then `Admit` sets the whole has_many list in one
  # `sets :members`. Every admitted handle was Joined first, so neither engine refuses.
  HAS_MANY_STEPS = [
    { "verb" => "HasManyFixture::Member.Join", "args" => { "handle" => { "value" => "alice" } } },
    { "verb" => "HasManyFixture::Member.Join", "args" => { "handle" => { "value" => "bob" } } },
    { "verb" => "HasManyFixture::Circle.Open", "args" => { "id" => { "value" => "c1" } } },
    { "verb" => "HasManyFixture::Circle.Admit",
      "args" => { "id" => { "value" => "c1" }, "members" => [{ "value" => "alice" }, { "value" => "bob" }] } }
  ].freeze

  it "the generated circle.rs no longer collapses the has_many list with the scalar .value fallback", :aggregate_failures do
    # Pinned against the generated source: the scalar `.value` unwrap must not be applied to a
    # whole `Vec`, and this fails before any cargo build does.
    source = File.read(GENERATED_CIRCLE)
    expect(source).to include("record.members = args.members.iter().map(|item| item.value.clone()).collect();")
    expect(source).not_to include(".value.clone();\n") # the old, bare (non-per-element) collapse
    expect(source).not_to include("ReferenceMember::from_json")
  end

  it "the generated has_many_fixture module actually compiles" do
    binary = build_rust_for("has_many_fixture")
    expect(binary).not_to be_nil, "rust/Cargo.toml has no has_many_fixture feature — run hecks project_rust " \
                                  "spec/fixtures/rust_project/has_many_fixture first (a failed build raises instead)"
  end

  # Builds the fixture's binary, skipping the example when the feature was never generated, runs
  # the steps through it, and returns its parsed output with event timestamps stripped.
  def rust_run(steps)
    binary = build_rust_for("has_many_fixture")
    skip "rust/Cargo.toml has no has_many_fixture feature — run hecks project_rust for it first" unless binary

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"
    JSON.parse(stdout).tap { |output| strip_occurred_at!(output["events"]) }
  end

  def round_trip(value) = JSON.parse(JSON.generate(value))

  # @return [Hash] the Ruby replay's instances and events as plain JSON, and its refusals
  def ruby_replay(steps)
    result = Hecks::Fuzzing::Replay.call(FIXTURE_DOMAIN, steps)
    { instances: round_trip(result[:instances]), events: round_trip(result[:events]), refusals: result[:refusals] }
  end

  # Both Joins and the Open: no has_many field is touched yet.
  def non_list_steps = HAS_MANY_STEPS.first(3)

  # Ruby's `Coercion#reference_list` keeps the Handle value objects, not bare ids.
  def ruby_member_ids(replay)
    members = replay[:instances].fetch("HasManyFixture::Circle#c1").fetch("members")
    members.map { |member| member.is_a?(Hash) ? member.fetch("value") : member }
  end

  it "a real command sequence round-trips through the compiled binary: has_many's own list serializes as bare " \
     "reference strings, never nested value objects", :aggregate_failures do
    rust_output = rust_run(HAS_MANY_STEPS)

    expect(rust_output["refusals"]).to eq([])
    # A `Reference<Member>` list stores bare ids, never `{"value": "alice"}` Handle objects.
    expect(rust_output["instances"]["HasManyFixture::Circle#c1"]["members"]).to eq(%w[alice bob])
    # `to_json` and `from_json` agree by construction; a shape mismatch in either direction
    # would surface as a `TypeMismatch` refusal above.
    expect(rust_output["mutations"].last.first["state"]["members"]).to eq(%w[alice bob])
  end

  it "Ruby and Rust agree on every step that leaves the has_many list alone (Member.Join, Circle.Open)", :aggregate_failures do
    rust_output = rust_run(non_list_steps)
    ruby_result = ruby_replay(non_list_steps)

    expect(rust_output["instances"]).to eq(ruby_result[:instances])
    expect(rust_output["events"]).to eq(ruby_result[:events])
    expect(rust_output["refusals"]).to eq([])
  end

  # Not a byte-for-byte parity claim on `members`: Ruby's `Coercion#reference_list` keeps the
  # Handle value objects, not bare ids. Normalized so this checks only which members were
  # admitted, in order.
  it "Ruby and Rust agree on WHICH members got admitted, modulo Ruby's separate reference_list shape gap", :aggregate_failures do
    rust_output = rust_run(HAS_MANY_STEPS)
    ruby_result = ruby_replay(HAS_MANY_STEPS)

    expect(ruby_result[:refusals]).to eq([])
    expect(rust_output["instances"]["HasManyFixture::Circle#c1"]["members"]).to eq(ruby_member_ids(ruby_result))
  end
end
