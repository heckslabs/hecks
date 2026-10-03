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

  def boot_referral_chain
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(REFERRAL_CHAIN_ROOT, "referral_chain.bluebook"))

      Hecks.hecksagon "ReferralChain" do
        attaches "Governance"

        ReferralChain::Sponsor.persisted_by("Memory")
        ReferralChain::Member.persisted_by("Memory")
        ReferralChain::Referral.persisted_by("Memory")
      end
      sibling_governance!
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

  # **The two-hop given** — `member.sponsor.standing`: `member` hydrates to
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

  # **The two-hop where** — `member/sponsor/standing`, walked by
  # `QuerySpecification::HopPath`; Rust refuses this query, so only Ruby answers it.
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

  # `Reassign` redeclares `member` under a plain `Handle`, so only the aggregate-level
  # settled-state reference check can see a dangling value.
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

  # The Rust side of the example above: the compiled binary must refuse `NotFound` and leave
  # `member` untouched, not store a dangling reference (ADR 0037).
  #
  # `io: true` — builds the referral_chain feature with cargo; excluded locally, run in CI.
  it "refuses to re-point a referral at a handle naming no member on the compiled Rust conformance binary too", :io do
    rust_dir = File.join(InMemoryDomain::ROOT, "rust")
    binary = build_rust_for("referral_chain", rust_dir)
    skip "rust/Cargo.toml has no referral_chain feature — run hecks project_rust for it first" unless binary

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

  # Dispatcher#dry_run? must refuse a dangling member like a real dispatch does:
  # `CommandInterpreter#step_save` returns before `resolve_state_references` on a dry run.
  it "answers dry_run? the same way a real dispatch would — a dangling member is refused, not accepted" do
    runtime
    chain!
    ReferralChain::Referral.issue!(code: { value: "r1" }, member: "m1")

    expect do
      runtime.dry_run?("ReferralChain::Referral.Reassign", code: { value: "r1" }, member: { value: "ghost" })
    end.to raise_error(Hecks::Runtime::NotFound, /no Member with handle "ghost"/)

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
