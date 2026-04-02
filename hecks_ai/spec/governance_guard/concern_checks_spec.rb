require "spec_helper"

RSpec.describe Hecks::GovernanceGuard::ConcernChecks do
  describe ".check_transparency" do
    it "returns violations for commands with emits []" do
      domain = Hecks.domain "T" do
        world_concerns :transparency
        aggregate "Record" do
          attribute :name, String
          command "DeleteRecord" do
            attribute :id, String
            emits []
          end
        end
      end

      violations, suggestions = described_class.check_transparency(domain)
      expect(violations.size).to eq(1)
      expect(violations.first[:concern]).to eq(:transparency)
      expect(suggestions).not_to be_empty
    end

    it "returns no violations for normal commands" do
      domain = Hecks.domain "T2" do
        aggregate "Record" do
          attribute :name, String
          command "CreateRecord" do
            attribute :name, String
          end
        end
      end

      violations, _suggestions = described_class.check_transparency(domain)
      expect(violations).to be_empty
    end
  end

  describe ".check_consent" do
    it "returns violations for user-like aggregates without actors" do
      domain = Hecks.domain "C" do
        aggregate "Patient" do
          attribute :name, String
          command "UpdatePatient" do
            attribute :name, String
          end
        end
      end

      violations, _suggestions = described_class.check_consent(domain)
      expect(violations.size).to eq(1)
      expect(violations.first[:concern]).to eq(:consent)
    end
  end

  describe ".check_privacy" do
    it "returns violations for visible PII" do
      domain = Hecks.domain "P" do
        aggregate "Patient" do
          attribute :ssn, String, pii: true
          command "CreatePatient" do
            attribute :ssn, String
            actor "Admin"
          end
        end
      end

      violations, _suggestions = described_class.check_privacy(domain)
      expect(violations.any? { |v| v[:message].include?("visible") }).to be true
    end
  end

  describe ".check_security" do
    it "returns violations for undeclared actors" do
      domain = Hecks.domain "S" do
        aggregate "Config" do
          attribute :key, String
          command "UpdateConfig" do
            attribute :key, String
            actor "Ghost"
          end
        end
      end

      violations, suggestions = described_class.check_security(domain)
      expect(violations.size).to eq(1)
      expect(violations.first[:concern]).to eq(:security)
      expect(suggestions).to include(/actor 'Ghost'/)
    end
  end
end
