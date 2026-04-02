require "spec_helper"

RSpec.describe Hecks::GovernanceGuard do
  def domain_with(name, concerns: [], &block)
    Hecks.domain(name, &block)
  end

  describe "#check" do
    it "passes with empty result when no world concerns declared" do
      domain = Hecks.domain "Clean" do
        aggregate("Widget") { attribute :name, String; command("CreateWidget") { attribute :name, String } }
      end
      result = described_class.new(domain).check
      expect(result.passed?).to be true
      expect(result.violations).to be_empty
    end

    context "transparency" do
      it "flags commands that emit no events" do
        domain = Hecks.domain "Opaque" do
          world_concerns :transparency
          aggregate("Record") { attribute :name, String; command("DeleteRecord") { attribute :id, String; emits [] } }
        end
        result = described_class.new(domain).check
        expect(result.passed?).to be false
        expect(result.violations.first[:concern]).to eq(:transparency)
        expect(result.violations.first[:message]).to include("DeleteRecord")
      end

      it "passes when commands emit events normally" do
        domain = Hecks.domain "Transparent" do
          world_concerns :transparency
          aggregate("Record") { attribute :name, String; command("CreateRecord") { attribute :name, String } }
        end
        expect(described_class.new(domain).check.passed?).to be true
      end
    end

    context "consent" do
      it "flags user-like aggregates with actor-less commands" do
        domain = Hecks.domain "NoConsent" do
          world_concerns :consent
          aggregate("Patient") { attribute :name, String; command("UpdatePatient") { attribute :name, String } }
        end
        result = described_class.new(domain).check
        expect(result.passed?).to be false
        expect(result.violations.first[:concern]).to eq(:consent)
        expect(result.violations.first[:message]).to include("Patient#UpdatePatient")
      end

      it "passes when user-like aggregate commands have actors" do
        domain = Hecks.domain "WithConsent" do
          world_concerns :consent
          aggregate "Patient" do
            attribute :name, String
            command("UpdatePatient") { attribute :name, String; actor "Doctor" }
          end
        end
        expect(described_class.new(domain).check.passed?).to be true
      end
    end

    context "privacy" do
      it "flags visible PII attributes" do
        domain = Hecks.domain "LeakyPII" do
          world_concerns :privacy
          aggregate "Patient" do
            attribute :ssn, String, pii: true
            command("CreatePatient") { attribute :ssn, String; actor "Admin" }
          end
        end
        result = described_class.new(domain).check
        expect(result.passed?).to be false
        expect(result.violations.any? { |v| v[:concern] == :privacy && v[:message].include?("visible") }).to be true
      end

      it "flags PII-aggregate commands without actors" do
        domain = Hecks.domain "NoAudit" do
          world_concerns :privacy
          aggregate "Patient" do
            attribute :ssn, String, pii: true, visible: false
            command("CreatePatient") { attribute :ssn, String }
          end
        end
        result = described_class.new(domain).check
        expect(result.violations.any? { |v| v[:message].include?("no actor") }).to be true
      end

      it "passes when PII is hidden and commands have actors" do
        domain = Hecks.domain "Secure" do
          world_concerns :privacy
          aggregate "Patient" do
            attribute :ssn, String, pii: true, visible: false
            command("CreatePatient") { attribute :ssn, String; actor "Admin" }
          end
        end
        expect(described_class.new(domain).check.passed?).to be true
      end
    end

    context "security" do
      it "flags command actors not declared at domain level" do
        domain = Hecks.domain "Dangling" do
          world_concerns :security
          aggregate("Config") { attribute :key, String; command("UpdateConfig") { attribute :key, String; actor "Ghost" } }
        end
        result = described_class.new(domain).check
        expect(result.passed?).to be false
        expect(result.violations.first[:concern]).to eq(:security)
        expect(result.violations.first[:message]).to include("Ghost")
      end

      it "passes when command actors match domain actors" do
        domain = Hecks.domain "Locked" do
          world_concerns :security
          actor "Admin"
          aggregate("Config") { attribute :key, String; command("UpdateConfig") { attribute :key, String; actor "Admin" } }
        end
        expect(described_class.new(domain).check.passed?).to be true
      end
    end

    context "multiple concerns" do
      it "collects violations from all declared concerns" do
        domain = Hecks.domain "Multi" do
          world_concerns :transparency, :consent
          aggregate("Patient") { attribute :name, String; command("DeletePatient") { attribute :id, String; emits [] } }
        end
        concerns = described_class.new(domain).check.violations.map { |v| v[:concern] }.uniq
        expect(concerns).to include(:transparency, :consent)
      end
    end

    it "works without API key via rule-based fallback" do
      domain = Hecks.domain "NoKey" do
        world_concerns :transparency
        aggregate("Record") { attribute :name, String; command("DeleteRecord") { attribute :id, String; emits [] } }
      end
      result = described_class.new(domain, api_key: nil).check
      expect(result.passed?).to be false
      expect(result.suggestions).not_to be_empty
    end
  end
end
