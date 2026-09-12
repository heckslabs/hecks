require "spec_helper"
require "open3"
require "hecks/fuzzing/form_census"

# `bin/qa_domain_novelty` — the gate a new stress domain passes before
# it becomes a `QualityControl::Target`: does it put two declared forms
# together, on one aggregate, that no existing target does? See the
# script's own header for the argument; this proves the script itself,
# as a real subprocess, over fixture domains and `--against` — never the
# ledger (`spec/quality_control_spec.rb`'s own rule: a spec that read
# the real ledger would depend on what every prior sweep left in it).
RSpec.describe "bin/qa_domain_novelty" do
  NOVELTY_FIXTURES = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_domain_novelty").freeze
  BASELINE = File.join(NOVELTY_FIXTURES, "baseline").freeze
  HOPPER   = File.join(NOVELTY_FIXTURES, "hopper").freeze

  def run_novelty(*args)
    Open3.capture3("bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_domain_novelty"), *args,
                   chdir: InMemoryDomain::ROOT)
  end

  it "names the pairs a candidate meets that the existing targets do not, and exits 0" do
    out, err, status = run_novelty(HOPPER, "--against", BASELINE)

    expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"
    expect(out).to include("multi_hop_where + reference_attr")
    expect(out).to include("has_query + multi_hop_where")
    expect(out).to include("Hopper::Proposal")
    expect(out).to include("earns its place")
    # Pairs baseline already meets are not news — Engagement carries
    # lifecycle + reference_attr on both sides.
    expect(out).not_to include("lifecycle + reference_attr")
  end

  it "exits 1, saying so, when every pair the candidate meets is already met" do
    out, _err, status = run_novelty(BASELINE, "--against", HOPPER)

    expect(status.exitstatus).to eq(1)
    expect(out).to include("no new pair")
    expect(out).to include("FormCensus::FORMS")
  end

  it "leaves the candidate's own path out of the comparison when it is already a target" do
    out, _err, status = run_novelty(HOPPER, "--against", HOPPER, BASELINE)

    expect(status.exitstatus).to eq(0)
    expect(out).to include("already a target — left out")
    expect(out).to include("multi_hop_where + reference_attr")
  end

  it "refuses a candidate that is not shaped <name>/bluebook/<name>.bluebook, exit 2" do
    _out, err, status = run_novelty(File.join(NOVELTY_FIXTURES, "flat.bluebook"), "--against", BASELINE)

    expect(status.exitstatus).to eq(2)
    expect(err).to include("not shaped like a stress domain")
    expect(err).to include("bluebook/flat.bluebook.bluebook")
  end

  it "reports, and skips, an --against path with nothing on disk rather than failing" do
    out, err, status = run_novelty(HOPPER, "--against", BASELINE, File.join(NOVELTY_FIXTURES, "__nowhere__"))

    expect(status.exitstatus).to eq(0)
    expect(err).to include("skipping").and include("__nowhere__")
    expect(out).to include("1 domain(s) from --against")
  end

  it "exits 2 with usage when given no candidate" do
    _out, err, status = run_novelty

    expect(status.exitstatus).to eq(2)
    expect(err).to include("usage: bin/qa_domain_novelty")
  end

  # THE WORKED EXAMPLE — the domain the reference-hop forms joined the
  # census for. Pinned here so the census and the domain cannot drift
  # apart: every form `qa/stress_domains/referral_chain` exists to
  # exercise has to keep reading true on the aggregate that carries it.
  describe "Hecks::Fuzzing::FormCensus over qa/stress_domains/referral_chain" do
    let(:census) { Hecks::Fuzzing::FormCensus.census(File.join(InMemoryDomain::ROOT, "qa/stress_domains/referral_chain")) }

    it "sees every reference-hop form on Referral, and none of them on Sponsor" do
      referral = census.find { |name, _| name == "ReferralChain::Referral" }.last
      sponsor  = census.find { |name, _| name == "ReferralChain::Sponsor" }.last

      hop_forms = %w[two_hop_given multi_hop_where revalued_reference]
      expect(referral.slice(*hop_forms).values).to all(be(true))
      expect(sponsor.slice(*hop_forms).values).to all(be(false))
      expect(referral["reference_attr"]).to be(true)
    end

    it "does not read a one-hop given as a two-hop one" do
      member = census.find { |name, _| name == "ReferralChain::Member" }.last
      expect(member["two_hop_given"]).to be(false)
    end
  end
end
