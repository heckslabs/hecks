require "spec_helper"

# The Assurance example: one engine judges a performance claim and a compliance claim, each to
# one of three outcomes, and a release is held until every claim it depends on is satisfied.
RSpec.describe "the Assurance example bluebook" do
  let(:domain) { Hecks.boot("examples/assurance/bluebook", install_driving: false) }

  def claim(name, direction:, limit:, verified_by:, subject: "booking", requirement: name)
    domain.dispatch("Assurance::Claim.Declare", with: {
      name: name, subject: subject, requirement: requirement,
      direction: direction, limit: limit, verified_by: verified_by
    })
  end

  def judge(name, measured:, scope: "staging")
    domain.dispatch("Assurance::Claim.Record", to: name, with: { measured: measured, scope: scope })
  end

  describe "a performance claim" do
    before { claim("p99", direction: "at_most", limit: 100, verified_by: "load_test", requirement: "p99 under 100 ms") }

    it "is inconclusive until evidence is recorded" do
      expect { domain.dispatch("Assurance::Claim.Satisfy", to: "p99", with: {}) }
        .to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "is satisfied when the measurement meets its ceiling" do
      judge("p99", measured: 80)
      expect(domain.dispatch("Assurance::Claim.Satisfy", to: "p99", with: {}).instance.outcome.value).to eq("satisfied")
    end

    it "is violated when the measurement exceeds its ceiling" do
      judge("p99", measured: 150)
      expect(domain.dispatch("Assurance::Claim.Violate", to: "p99", with: {}).instance.outcome.value).to eq("violated")
    end
  end

  describe "a compliance claim" do
    before { claim("audit", direction: "at_least", limit: 95, verified_by: "audit_sample", requirement: "privileged actions audited") }

    it "is satisfied when coverage meets its floor" do
      judge("audit", measured: 97, scope: "Q4 sample")
      expect(domain.dispatch("Assurance::Claim.Satisfy", to: "audit", with: {}).instance.outcome.value).to eq("satisfied")
    end

    it "is violated when coverage falls under its floor" do
      judge("audit", measured: 90, scope: "Q4 sample")
      expect(domain.dispatch("Assurance::Claim.Violate", to: "audit", with: {}).instance.outcome.value).to eq("violated")
    end
  end

  describe "a release" do
    before do
      claim("p99", direction: "at_most", limit: 100, verified_by: "load_test")
      claim("audit", direction: "at_least", limit: 95, verified_by: "audit_sample")
      domain.dispatch("Assurance::Deployment.Open", with: { name: "release-1" })
      domain.dispatch("Assurance::Deployment.Require", to: "release-1", with: { claim: "p99" })
      domain.dispatch("Assurance::Deployment.Require", to: "release-1", with: { claim: "audit" })
    end

    def release! = domain.dispatch("Assurance::Deployment.Release", to: "release-1", with: {})

    it "is held while any required claim is unsatisfied" do
      judge("p99", measured: 80)
      domain.dispatch("Assurance::Claim.Satisfy", to: "p99", with: {})
      domain.dispatch("Assurance::Deployment.Satisfied", to: "release-1", with: { claim: "p99" })

      expect { release! }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "is held when a required claim is violated and never reaches the release" do
      judge("p99", measured: 80)
      judge("audit", measured: 90)
      domain.dispatch("Assurance::Claim.Satisfy", to: "p99", with: {})
      domain.dispatch("Assurance::Claim.Violate", to: "audit", with: {})
      domain.dispatch("Assurance::Deployment.Satisfied", to: "release-1", with: { claim: "p99" })

      expect { release! }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "is released once every required claim is satisfied" do
      judge("p99", measured: 80)
      judge("audit", measured: 97)
      domain.dispatch("Assurance::Claim.Satisfy", to: "p99", with: {})
      domain.dispatch("Assurance::Claim.Satisfy", to: "audit", with: {})
      domain.dispatch("Assurance::Deployment.Satisfied", to: "release-1", with: { claim: "p99" })
      domain.dispatch("Assurance::Deployment.Satisfied", to: "release-1", with: { claim: "audit" })

      expect(release!.instance.status.value).to eq("released")
    end

    # Known gap: the expression language cannot see a command's own arguments inside a `given`,
    # so Satisfied cannot refuse a claim that is not required, or one already counted. A repeated
    # Satisfied therefore counts twice. Closing it needs membership over the argument, not state.
    it "does not count the same claim twice", pending: "expression guards cannot see command arguments" do
      judge("p99", measured: 80)
      domain.dispatch("Assurance::Claim.Satisfy", to: "p99", with: {})
      domain.dispatch("Assurance::Deployment.Satisfied", to: "release-1", with: { claim: "p99" })
      domain.dispatch("Assurance::Deployment.Satisfied", to: "release-1", with: { claim: "p99" })

      expect { release! }.to raise_error(Hecks::Runtime::GivenNotMet)
    end
  end
end
