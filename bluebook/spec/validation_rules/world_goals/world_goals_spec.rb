require "spec_helper"

RSpec.describe "World Goals validation rules" do
  def validate(domain)
    validator = Hecks::Validator.new(domain)
    [validator.valid?, validator.errors]
  end

  describe "no goals declared" do
    it "passes with no world goals" do
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
        world_goals :transparency
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
        world_goals :transparency
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
        world_goals :consent
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
        world_goals :consent
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
        world_goals :privacy
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
        world_goals :privacy
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
        world_goals :privacy
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

  describe ":security" do
    it "flags command actors not declared at domain level" do
      domain = Hecks.domain "Dangling" do
        world_goals :security
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
        world_goals :security
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
