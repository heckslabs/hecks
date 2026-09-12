require "spec_helper"
require "json"
require "open3"
require_relative "support/rust_conformance_helpers"

# qa/stress_domains/referral_chain — see its own NOTES.md and the header
# comment on referral_chain.bluebook for why this domain exists: a
# three-aggregate `reference_to` chain (Referral -> Member -> Sponsor,
# ANGLE-2 in the QA ledger) walking every hop the runtime's reference
# machinery has — a one-hop and a two-hop `given` through a fresh
# argument, a two-hop `where`, and a reference re-pointed through a
# plain value object so only a settled-state reference check can catch a
# dangling one.
#
# These pin the RUBY side's answers — the reference the differential
# harness compares Rust against. `Referral.Reassign`'s own example used
# to be the one Rust disagreed with on the first real run (NOTES.md,
# "What this domain found") — QualityControl BUG#26 / ADR 0037 Finding 5,
# reopened by this domain and CLOSED by `rust/project/domain_generator.rb
# #state_reference_checks` (mirrored in `rust/codegen/src/domain_
# generator.rs`): a revalued reference redeclared under a plain value
# object is now checked at the router, against the AGGREGATE's own
# `Reference<X>` attribute, the same pre-dispatch shape `reference_checks`
# already used for an ordinary `reference_to` command argument.
RSpec.describe "ReferralChain" do
  include RustConformanceHelpers

  REFERRAL_CHAIN_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/referral_chain/bluebook").freeze

  def boot_referral_chain
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(REFERRAL_CHAIN_ROOT, "referral_chain.bluebook"))

      Hecks.hecksagon "ReferralChain" do
        uses_framework "Governance"

        ReferralChain::Sponsor.persisted_by("Memory")
        ReferralChain::Member.persisted_by("Memory")
        ReferralChain::Referral.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_referral_chain }

  def chain!(sponsor: "s1", member: "m1")
    ReferralChain::Sponsor.enroll!(handle: { value: sponsor })
    ReferralChain::Member.join!(handle: { value: member }, sponsor: sponsor)
  end

  it "joins a member under a sponsor in good standing — the one-hop given holds" do
    runtime
    chain!
    expect(ReferralChain::Member.find("m1")[:sponsor]).to eq("s1")
  end

  it "refuses to join under a suspended sponsor — the one-hop given reads the referenced sponsor's own state" do
    runtime
    ReferralChain::Sponsor.enroll!(handle: { value: "s1" })
    ReferralChain::Sponsor.find("s1").suspend!

    expect { ReferralChain::Member.join!(handle: { value: "m1" }, sponsor: "s1") }
      .to raise_error(Hecks::Runtime::GivenNotMet, /the sponsor is in good standing/)
  end

  # THE TWO-HOP GIVEN — `member.sponsor.standing`: `member` hydrates to
  # the Member's state, whose own `sponsor` hydrates one hop further
  # (`CommandRules::References#dereference` recursing).
  it "issues a referral while the member's sponsor stands in good standing, and refuses once that sponsor is suspended" do
    runtime
    chain!
    ReferralChain::Referral.issue!(code: { value: "r1" }, member: "m1")
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m1")

    ReferralChain::Sponsor.find("s1").suspend!
    expect { ReferralChain::Referral.issue!(code: { value: "r2" }, member: "m1") }
      .to raise_error(Hecks::Runtime::GivenNotMet, /the member's sponsor is in good standing/)
  end

  # THE TWO-HOP WHERE — `member/sponsor/standing`, walked by
  # `QuerySpecification::HopPath`; Rust structurally refuses this query,
  # so Ruby's own answer here is the only one the practice has.
  it "answers the two-hop where by the sponsor two references away, not by anything the referral itself stores" do
    runtime
    chain!(sponsor: "good", member: "gm")
    chain!(sponsor: "bad", member: "bm")
    ReferralChain::Referral.issue!(code: { value: "from-good" }, member: "gm")
    ReferralChain::Referral.issue!(code: { value: "from-bad" }, member: "bm")
    ReferralChain::Sponsor.find("bad").suspend!

    codes = runtime.query("ReferralChain::Referral.FromGoodSponsors").map { |row| row[:code][:value] }
    expect(codes).to eq(["from-good"])
  end

  # THE ADR 0037 FINDING 5 SHAPE — `Reassign` redeclares `member` under a
  # plain `Handle`, so the command-level reference check on the command's
  # OWN attribute sees nothing to check (it isn't `reference?`-true); a
  # SECOND, aggregate-level check (`state_reference_checks`, domain_
  # generator.rb — Rust's own port of this shape) asks whether the value
  # actually names a real Member, resolved against the AGGREGATE's own
  # `Reference<Member>` attribute of the same name instead.
  it "re-points a referral at an existing member through a plain handle" do
    runtime
    chain!
    ReferralChain::Member.join!(handle: { value: "m2" }, sponsor: "s1")
    ReferralChain::Referral.issue!(code: { value: "r1" }, member: "m1")

    ReferralChain::Referral.find("r1").reassign!(member: { value: "m2" })
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m2")
  end

  it "refuses to re-point a referral at a handle naming no member" do
    runtime
    chain!
    ReferralChain::Referral.issue!(code: { value: "r1" }, member: "m1")

    expect { ReferralChain::Referral.find("r1").reassign!(member: { value: "ghost" }) }
      .to raise_error(Hecks::Runtime::NotFound, /no Member with handle "ghost"/)
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m1")
  end

  # BUG#26 (QualityControl ledger) / ADR 0037 FINDING 5, REOPENED — the
  # RUST SIDE of the example just above. Before `rust/project/domain_
  # generator.rb#state_reference_checks` (mirrored in `rust/codegen/src/
  # domain_generator.rs`), the compiled conformance binary accepted this
  # exact sequence, emitted `ReferralReassigned`, and stored `member:
  # "ghost"` as a dangling reference — confirmed live, reproduced via
  # `Hecks::Fuzzing::SequenceGenerator.generate("qa/stress_domains/
  # referral_chain", seed: 2, steps: 25, adversarial: 0.3)`, replayed
  # through `Hecks::Fuzzing::Replay` against the compiled binary. Both
  # engines now refuse `NotFound`, byte-for-byte on the refusal KIND
  # (C8.2 — prose is not the contract), and both leave the referral's own
  # `member` field untouched.
  #
  # `io: true` — a real `cargo build --features referral_chain`, same as
  # every other spec doing genuine Rust I/O (rust_conformance_spec.rb,
  # rust_conformance_fuzz_spec.rb); excluded locally by default
  # (spec_helper.rb), always run in CI.
  it "refuses to re-point a referral at a handle naming no member on the compiled Rust conformance binary too", :io do
    rust_dir = File.join(InMemoryDomain::ROOT, "rust")
    binary = build_rust_for("referral_chain", rust_dir)
    skip "rust/Cargo.toml has no referral_chain feature — run bin/project_rust for it first" unless binary

    steps = [
      { "verb" => "ReferralChain::Sponsor.Enroll", "args" => { "handle" => { "value" => "s1" } } },
      { "verb" => "ReferralChain::Member.Join", "args" => { "sponsor" => "s1", "handle" => { "value" => "m1" } } },
      { "verb" => "ReferralChain::Referral.Issue", "args" => { "member" => "m1", "code" => { "value" => "r1" } } },
      { "verb" => "ReferralChain::Referral.Reassign", "args" => { "code" => { "value" => "r1" }, "member" => { "value" => "ghost" } } }
    ]

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
    expect(status).to be_success, "rust exited #{status.exitstatus}: #{stdout}"
    rust_output = JSON.parse(stdout)

    reassign_refusals = rust_output.fetch("refusals").select { |r| r["verb"] == "ReferralChain::Referral.Reassign" }
    expect(reassign_refusals.map { |r| r["kind"] }).to eq(["NotFound"])
    expect(reassign_refusals.first["error"]).to include('no Member with handle "ghost"')

    referral = rust_output.fetch("instances")["ReferralChain::Referral#r1"]
    expect(referral["member"]).to eq("m1"), "Rust must not persist a dangling member reference"
  end

  it "gates Suspend on the Registrar role when a caller states one" do
    runtime
    ReferralChain::Sponsor.enroll!(handle: { value: "s1" })

    expect { Hecks.as_caller(role: "Nobody") { ReferralChain::Sponsor.find("s1").suspend! } }
      .to raise_error(Hecks::Runtime::Unauthorized)
    Hecks.as_caller(role: "Registrar") { ReferralChain::Sponsor.find("s1").suspend! }
    expect(ReferralChain::Sponsor.find("s1")[:standing]).to eq("suspended")
  end
end
