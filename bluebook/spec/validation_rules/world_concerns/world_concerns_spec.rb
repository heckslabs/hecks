require "spec_helper"

RSpec.describe "World Concerns validation rules" do
  def validate(domain)
    validator = Hecks::Validator.new(domain)
    [validator.valid?, validator.errors]
  end

  describe "no concerns declared" do
    it "passes with no world concerns" do
      domain = Hecks.domain "Clean" do
        aggregate "Widget" do
          attribute :name, String
          command "CreateWidget" do
            attribute :name, String
          end
        end
      end

      valid, _errors = validate(domain)
      expect(valid).to be true
    end
  end

  describe ":transparency" do
    it "flags commands that emit no events" do
      domain = Hecks.domain "Opaque" do
        world_concerns :transparency
        aggregate "Record" do
          attribute :name, String
          command "DeleteRecord" do
            attribute :id, String
            emits []
          end
        end
      end

      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors).to include(/Transparency.*DeleteRecord.*emits no events/)
    end

    it "passes when commands emit events normally" do
      domain = Hecks.domain "Transparent" do
        world_concerns :transparency
        aggregate "Record" do
          attribute :name, String
          command "CreateRecord" do
            attribute :name, String
          end
        end
      end

      valid, _errors = validate(domain)
      expect(valid).to be true
    end
  end

  describe ":consent" do
    it "flags user-like aggregates with actor-less commands" do
      domain = Hecks.domain "NoConsent" do
        world_concerns :consent
        aggregate "Patient" do
          attribute :name, String
          command "UpdatePatient" do
            attribute :name, String
          end
        end
      end

      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors).to include(/Consent.*Patient#UpdatePatient.*no actor/)
    end

    it "passes when user-like aggregate commands have actors" do
      domain = Hecks.domain "WithConsent" do
        world_concerns :consent
        aggregate "Patient" do
          attribute :name, String
          command "UpdatePatient" do
            attribute :name, String
            actor "Doctor"
          end
        end
      end

      valid, _errors = validate(domain)
      expect(valid).to be true
    end
  end

  describe ":privacy" do
    it "flags PII attributes that are visible" do
      domain = Hecks.domain "LeakyPII" do
        world_concerns :privacy
        aggregate "Patient" do
          attribute :ssn, String, pii: true
          command "CreatePatient" do
            attribute :ssn, String
            actor "Admin"
          end
        end
      end

      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors).to include(/Privacy.*Patient#ssn.*PII but visible/)
    end

    it "flags PII aggregate commands without actors" do
      domain = Hecks.domain "NoAudit" do
        world_concerns :privacy
        aggregate "Patient" do
          attribute :ssn, String, pii: true, visible: false
          command "CreatePatient" do
            attribute :ssn, String
          end
        end
      end

      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors).to include(/Privacy.*CreatePatient.*touches PII.*no actor/)
    end

    it "passes when PII is hidden and commands have actors" do
      domain = Hecks.domain "Secure" do
        world_concerns :privacy
        aggregate "Patient" do
          attribute :ssn, String, pii: true, visible: false
          command "CreatePatient" do
            attribute :ssn, String
            actor "Admin"
          end
        end
      end

      valid, _errors = validate(domain)
      expect(valid).to be true
    end
  end

  describe "world_concerns_report" do
    it "returns nil when no concerns declared and reports failing concerns" do
      # No concerns => nil
      no_concerns = Hecks.domain "Plain" do
        aggregate "Widget" do
          attribute :name, String
          command "CreateWidget" do
            attribute :name, String
          end
        end
      end
      v1 = Hecks::Validator.new(no_concerns)
      v1.valid?
      expect(v1.world_concerns_report).to be_nil

      # Failing concern => report with failing_concerns populated
      failing = Hecks.domain "Opaque" do
        world_concerns :transparency
        aggregate "Record" do
          attribute :name, String
          command "DeleteRecord" do
            attribute :id, String
            emits []
          end
        end
      end
      v2 = Hecks::Validator.new(failing)
      v2.valid?
      report = v2.world_concerns_report
      expect(report[:concerns_declared]).to eq([:transparency])
      expect(report[:failing_concerns]).to eq([:transparency])
      expect(report[:passing_concerns]).to be_empty
      expect(report[:violations]).to include(/Transparency/)
    end
  end

  describe ":security" do
    it "flags command actors not declared at domain level" do
      domain = Hecks.domain "Dangling" do
        world_concerns :security
        aggregate "Config" do
          attribute :key, String
          command "UpdateConfig" do
            attribute :key, String
            actor "Ghost"
          end
        end
      end

      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors).to include(/Security.*UpdateConfig.*'Ghost'.*not a domain-level actor/)
    end

    it "passes when command actors match domain actors" do
      domain = Hecks.domain "Locked" do
        world_concerns :security
        actor "Admin"
        aggregate "Config" do
          attribute :key, String
          command "UpdateConfig" do
            attribute :key, String
            actor "Admin"
          end
        end
      end

      valid, _errors = validate(domain)
      expect(valid).to be true
    end
  end
end
