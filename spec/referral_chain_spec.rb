require "spec_helper"

# qa/stress_domains/referral_chain — see its own NOTES.md and the header
# comment on referral_chain.bluebook for why this domain exists: a
# three-aggregate `reference_to` chain (Referral -> Member -> Sponsor,
# ANGLE-2 in the QA ledger) walking every hop the runtime's reference
# machinery has — a one-hop and a two-hop `given` through a fresh
# argument, a two-hop `where`, and a reference re-pointed through a
# plain value object so only `resolve_state_references` (never ported to
# Rust — ADR 0037 Finding 5) can catch a dangling one.
#
# These pin the RUBY side's answers — the reference the differential
# harness compares Rust against. `Referral.Reassign`'s own example is
# the one Rust disagrees with on the first real run (NOTES.md, "What
# this domain found"): a regression pin for Ruby, and the demonstration
# the ledger's own Bug wants, in one place.
RSpec.describe "ReferralChain" do
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
  # plain `Handle`, so the command-level reference check (the one Rust
  # ported) sees nothing to check; only `resolve_state_references`, at
  # `step_save`, asks whether the settled `member` names a real Member.
  it "re-points a referral at an existing member through a plain handle" do
    runtime
    chain!
    ReferralChain::Member.join!(handle: { value: "m2" }, sponsor: "s1")
    ReferralChain::Referral.issue!(code: { value: "r1" }, member: "m1")

    ReferralChain::Referral.find("r1").reassign!(member: { value: "m2" })
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m2")
  end

  it "refuses to re-point a referral at a handle naming no member — the settled-state reference check, Ruby's alone" do
    runtime
    chain!
    ReferralChain::Referral.issue!(code: { value: "r1" }, member: "m1")

    expect { ReferralChain::Referral.find("r1").reassign!(member: { value: "ghost" }) }
      .to raise_error(Hecks::Runtime::NotFound, /no Member with handle "ghost"/)
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m1")
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
