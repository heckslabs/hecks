require "spec_helper"
require "json"
require "open3"
require_relative "support/rust_conformance_helpers"

# qa/stress_domains/referral_chain: a Referral -> Member -> Sponsor `reference_to` chain that
# exercises one- and two-hop `given`, a two-hop `where`, and a reference re-pointed through a
# plain value object. These pin the Ruby answers the differential harness compares Rust against.
RSpec.describe "ReferralChain" do
  include RustConformanceHelpers

  REFERRAL_CHAIN_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/referral_chain/bluebook").freeze

  # The reassignment of a referral to a handle that names no member, as the Rust binary is asked.
  REFERRAL_CHAIN_STEPS = [
    { "verb" => "ReferralChain::Sponsor.Enroll", "args" => { "handle" => { "value" => "s1" } } },
    { "verb" => "ReferralChain::Member.Join", "args" => { "sponsor" => "s1", "handle" => { "value" => "m1" } } },
    { "verb" => "ReferralChain::Referral.Issue", "args" => { "member" => "m1", "code" => { "value" => "r1" } } },
    { "verb" => "ReferralChain::Referral.Reassign", "args" => { "code" => { "value" => "r1" }, "member" => { "value" => "ghost" } } }
  ].freeze

  def declare_referral_chain_hecksagon
    Hecks.hecksagon "ReferralChain" do
      attaches "Governance"

      ReferralChain::Sponsor.persisted_by("Memory")
      ReferralChain::Member.persisted_by("Memory")
      ReferralChain::Referral.persisted_by("Memory")
    end
  end

  def load_referral_chain
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::PRISM_ADAPTER, File.join(REFERRAL_CHAIN_ROOT, "referral_chain.bluebook")].each { |file| Kernel.load(file) }
    declare_referral_chain_hecksagon
    sibling_governance!
  end

  def boot_referral_chain
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) { load_referral_chain }

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let!(:runtime) { boot_referral_chain }

  def chain!(sponsor: "s1", member: "m1")
    ReferralChain::Sponsor.enroll!(handle: { value: sponsor })
    ReferralChain::Member.join!(handle: { value: member }, sponsor: sponsor)
  end

  # A member under `sponsor` who has issued a referral coded `code`.
  def referral_via(sponsor:, member:, code:)
    chain!(sponsor: sponsor, member: member)
    ReferralChain::Referral.issue!(code: { value: code }, member: member)
  end

  # What the compiled conformance binary answers for the steps that re-point a referral at a ghost.
  def run_rust_steps(binary)
    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => REFERRAL_CHAIN_STEPS }))
    expect(status).to be_success, "rust exited #{status.exitstatus}: #{stdout}"
    JSON.parse(stdout)
  end

  def ghost_refusal
    a_hash_including("kind" => "NotFound", "error" => a_string_including('no Member with handle "ghost"'))
  end

  def rust_member(output) = output.fetch("instances")["ReferralChain::Referral#r1"]["member"]

  def reassign_refusals(output)
    output.fetch("refusals").select { |refusal| refusal["verb"] == "ReferralChain::Referral.Reassign" }
  end

  it "joins a member under a sponsor in good standing — the one-hop given holds" do
    chain!
    expect(ReferralChain::Member.find("m1")[:sponsor]).to eq("s1")
  end

  it "refuses to join under a suspended sponsor — the one-hop given reads the referenced sponsor's own state" do
    ReferralChain::Sponsor.enroll!(handle: { value: "s1" })
    ReferralChain::Sponsor.find("s1").suspend!

    expect { ReferralChain::Member.join!(handle: { value: "m1" }, sponsor: "s1") }
      .to raise_error(Hecks::Runtime::GivenNotMet, /the sponsor is in good standing/)
  end

  # **The two-hop given** — `member.sponsor.standing`: `member` hydrates to
  # the Member's state, whose own `sponsor` hydrates one hop further
  # (`CommandRules::References#dereference` recursing).
  it "issues a referral while the member's sponsor stands in good standing" do
    referral_via(sponsor: "s1", member: "m1", code: "r1")

    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m1")
  end

  it "refuses to issue a referral once the member's sponsor is suspended" do
    chain!
    ReferralChain::Sponsor.find("s1").suspend!

    expect { ReferralChain::Referral.issue!(code: { value: "r2" }, member: "m1") }
      .to raise_error(Hecks::Runtime::GivenNotMet, /the member's sponsor is in good standing/)
  end

  # **The two-hop where** — `member/sponsor/standing`, walked by
  # `QuerySpecification::HopPath`; Rust refuses this query, so only Ruby answers it.
  it "answers the two-hop where by the sponsor two references away, not by anything the referral itself stores" do
    referral_via(sponsor: "good", member: "gm", code: "from-good")
    referral_via(sponsor: "bad", member: "bm", code: "from-bad")
    ReferralChain::Sponsor.find("bad").suspend!

    codes = runtime.query("ReferralChain::Referral.FromGoodSponsors").map { |row| row[:code][:value] }
    expect(codes).to eq(["from-good"])
  end

  # `Reassign` redeclares `member` under a plain `Handle`, so only the aggregate-level
  # settled-state reference check can see a dangling value.
  it "re-points a referral at an existing member through a plain handle" do
    referral_via(sponsor: "s1", member: "m1", code: "r1")
    ReferralChain::Member.join!(handle: { value: "m2" }, sponsor: "s1")

    ReferralChain::Referral.find("r1").reassign!(member: { value: "m2" })
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m2")
  end

  it "refuses to re-point a referral at a handle naming no member", :aggregate_failures do
    referral_via(sponsor: "s1", member: "m1", code: "r1")

    expect { ReferralChain::Referral.find("r1").reassign!(member: { value: "ghost" }) }
      .to raise_error(Hecks::Runtime::NotFound, /no Member with handle "ghost"/)
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m1")
  end

  # The Rust side of the example above: the compiled binary must refuse `NotFound` and leave
  # `member` untouched, not store a dangling reference (ADR 0037).
  #
  # `io: true` — builds the referral_chain feature with cargo; excluded locally, run in CI.
  it "refuses to re-point a referral at a handle naming no member on the compiled Rust conformance binary too",
     :aggregate_failures, :io do
    binary = build_rust_for("referral_chain", File.join(InMemoryDomain::ROOT, "rust"))
    skip "rust/Cargo.toml has no referral_chain feature — run hecks project_rust for it first" unless binary
    output = run_rust_steps(binary)

    expect(reassign_refusals(output)).to match([ghost_refusal])
    expect(rust_member(output)).to eq("m1"), "Rust must not persist a dangling member reference"
  end

  # Dispatcher#dry_run? must refuse a dangling member like a real dispatch does:
  # `CommandInterpreter#step_save` returns before `resolve_state_references` on a dry run.
  it "answers dry_run? the same way a real dispatch would — a dangling member is refused, not accepted", :aggregate_failures do
    referral_via(sponsor: "s1", member: "m1", code: "r1")

    expect { runtime.dry_run?("ReferralChain::Referral.Reassign", code: { value: "r1" }, member: { value: "ghost" }) }
      .to raise_error(Hecks::Runtime::NotFound, /no Member with handle "ghost"/)
    expect(ReferralChain::Referral.find("r1")[:member]).to eq("m1")
  end

  it "gates Suspend on the Registrar role when a caller states one", :aggregate_failures do
    ReferralChain::Sponsor.enroll!(handle: { value: "s1" })

    expect { Hecks.as_caller(role: "Nobody") { ReferralChain::Sponsor.find("s1").suspend! } }
      .to raise_error(Hecks::Runtime::Unauthorized)
    Hecks.as_caller(role: "Registrar") { ReferralChain::Sponsor.find("s1").suspend! }
    expect(ReferralChain::Sponsor.find("s1")[:standing]).to eq("suspended")
  end
end
