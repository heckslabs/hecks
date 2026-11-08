require "spec_helper"

# The Assurance example: one engine judges a performance claim and a compliance claim, each to
# one of three outcomes, and a release is held until every claim it depends on is satisfied.
RSpec.describe "the Assurance example bluebook" do
  let(:domain) { Hecks.boot("examples/assurance/bluebook", install_driving: false) }

  def claim(name, **facts)
    facts = { subject: "booking", requirement: name }.merge(facts)
    domain.dispatch("Assurance::Claim.Declare", with: { name: name, **facts })
  end

  def judge(name, measured:, scope: "staging")
    domain.dispatch("Assurance::Claim.Record", to: name, with: { measured: measured, scope: scope })
  end

  def satisfy(name) = domain.dispatch("Assurance::Claim.Satisfy", to: name, with: {})

  def violate(name) = domain.dispatch("Assurance::Claim.Violate", to: name, with: {})

  def outcome_after_recording(name, measured) = judge(name, measured: measured).instance.outcome.value

  describe "a performance claim" do
    before { claim("p99", direction: "at_most", limit: 100, verified_by: "load_test", requirement: "p99 under 100 ms") }

    it "is inconclusive until evidence is recorded" do
      expect { satisfy("p99") }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "is satisfied when the measurement meets its ceiling" do
      judge("p99", measured: 80)
      expect(satisfy("p99").instance.outcome.value).to eq("satisfied")
    end

    it "is violated when the measurement exceeds its ceiling" do
      judge("p99", measured: 150)
      expect(violate("p99").instance.outcome.value).to eq("violated")
    end
  end

  describe "a compliance claim" do
    before do
      claim("audit", direction: "at_least", limit: 95, verified_by: "audit_sample", requirement: "privileged actions audited")
    end

    it "is satisfied when coverage meets its floor" do
      judge("audit", measured: 97, scope: "Q4 sample")
      expect(satisfy("audit").instance.outcome.value).to eq("satisfied")
    end

    it "is violated when coverage falls under its floor" do
      judge("audit", measured: 90, scope: "Q4 sample")
      expect(violate("audit").instance.outcome.value).to eq("violated")
    end
  end

  describe "re-recording evidence" do
    before do
      claim("p99", direction: "at_most", limit: 100, verified_by: "load_test")
      judge("p99", measured: 80)
    end

    it "leaves a satisfied claim inconclusive until it is judged again" do
      satisfy("p99")
      expect(outcome_after_recording("p99", 80)).to eq("inconclusive")
    end

    it "lets a violated claim be re-recorded and judged satisfied", :aggregate_failures do
      judge("p99", measured: 150)
      violate("p99")
      expect(outcome_after_recording("p99", 80)).to eq("inconclusive")
      expect(satisfy("p99").instance.outcome.value).to eq("satisfied")
    end

    it "lets a satisfied claim be re-recorded and judged violated", :aggregate_failures do
      satisfy("p99")
      expect(outcome_after_recording("p99", 150)).to eq("inconclusive")
      expect(violate("p99").instance.outcome.value).to eq("violated")
    end
  end

  describe "a release" do
    before do
      claim("p99", direction: "at_most", limit: 100, verified_by: "load_test")
      claim("audit", direction: "at_least", limit: 95, verified_by: "audit_sample")
      domain.dispatch("Assurance::Deployment.Open", with: { name: "release-1" })
    end

    def require_claim(name) = domain.dispatch("Assurance::Deployment.Require", to: "release-1", with: { claim: name })

    def satisfied_for_release(name)
      domain.dispatch("Assurance::Deployment.RequiredClaim.Satisfied",
                      to: { aggregate: "release-1", entity: name }, with: { claim: name })
    end

    def release! = domain.dispatch("Assurance::Deployment.Release", to: "release-1", with: {})

    def judge_satisfied(name, measured)
      judge(name, measured: measured)
      satisfy(name)
      satisfied_for_release(name)
    end

    it "is held while it requires no claim" do
      expect { release! }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    def require_both = %w[p99 audit].each { |name| require_claim(name) }

    it "is held while any required claim is unsatisfied" do
      require_both
      judge_satisfied("p99", 80)
      expect { release! }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "is held when a required claim is violated and never reaches the release" do
      require_both
      judge_satisfied("p99", 80)
      judge("audit", measured: 90) && violate("audit")
      expect { release! }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "is released once every required claim is satisfied" do
      require_both
      judge_satisfied("p99", 80)
      judge_satisfied("audit", 97)
      expect(release!.instance.status.value).to eq("released")
    end

    it "does not count the same claim twice" do
      require_claim("p99")
      expect { require_claim("p99") }.to raise_error(Hecks::Runtime::AlreadyExists, /RequiredClaim.*already exists/)
    end

    it "refuses by name to satisfy a claim that was never required" do
      require_claim("p99")
      expect { satisfied_for_release("audit") }.to raise_error(Hecks::Runtime::NotFound, /no RequiredClaim/)
    end
  end
end
