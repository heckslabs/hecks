require "spec_helper"

RSpec.describe Hecks::ValidationRules::Naming::GlossaryTermViolations do
  def build_domain(&block)
    Hecks.domain("TestDomain", &block)
  end

  def validate(domain)
    v = Hecks::Validator.new(domain)
    [v.valid?, v.errors, v.warnings]
  end

  describe "with empty glossary" do
    it "produces no warnings or errors" do
      domain = build_domain do
        aggregate "Customer" do
          attribute :name, String
          command "CreateCustomer" do
            attribute :name, String
          end
        end
      end

      valid, errors, warnings = validate(domain)
      expect(valid).to be true
      expect(errors).to be_empty
      expect(warnings).to be_empty
    end
  end

  describe "default (non-strict) mode" do
    let(:domain) do
      build_domain do
        glossary do
          prefer "stakeholder", not: ["user", "person"]
        end

        aggregate "UserProfile" do
          attribute :user_name, String
          command "CreateUserProfile" do
            attribute :user_name, String
          end
        end
      end
    end

    it "is still valid (warnings, not errors)" do
      valid, _errors, _warnings = validate(domain)
      expect(valid).to be true
    end

    it "warns about aggregate name containing banned term" do
      _valid, _errors, warnings = validate(domain)
      expect(warnings).to include(a_string_matching(/Aggregate 'UserProfile' contains avoided term 'user'/))
      expect(warnings).to include(a_string_matching(/prefer 'stakeholder'/))
    end

    it "warns about attribute name containing banned term" do
      _valid, _errors, warnings = validate(domain)
      expect(warnings).to include(a_string_matching(/Attribute 'user_name'.*contains avoided term 'user'/))
    end

    it "warns about command name containing banned term" do
      _valid, _errors, warnings = validate(domain)
      expect(warnings).to include(a_string_matching(/Command 'CreateUserProfile' contains avoided term 'user'/))
    end

    it "produces no errors in non-strict mode" do
      _valid, errors, _warnings = validate(domain)
      glossary_errors = errors.select { |e| e.include?("avoided term") }
      expect(glossary_errors).to be_empty
    end
  end

  describe "strict mode" do
    let(:domain) do
      build_domain do
        glossary(strict: true) do
          prefer "stakeholder", not: ["user"]
        end

        aggregate "UserAccount" do
          attribute :name, String
          command "CreateUserAccount" do
            attribute :name, String
          end
        end
      end
    end

    it "makes valid? return false" do
      valid, _errors, _warnings = validate(domain)
      expect(valid).to be false
    end

    it "reports glossary violations as errors" do
      _valid, errors, _warnings = validate(domain)
      expect(errors).to include(a_string_matching(/Aggregate 'UserAccount' contains avoided term 'user'/))
    end

    it "does not duplicate violations in warnings in strict mode" do
      _valid, _errors, warnings = validate(domain)
      glossary_warnings = warnings.select { |w| w.include?("avoided term") }
      expect(glossary_warnings).to be_empty
    end
  end

  describe "no false positives" do
    it "does not flag 'Customer' when only 'user' is banned" do
      domain = build_domain do
        glossary do
          prefer "stakeholder", not: ["user"]
        end

        aggregate "Customer" do
          attribute :name, String
          command "CreateCustomer" do
            attribute :name, String
          end
        end
      end

      _valid, _errors, warnings = validate(domain)
      glossary_warnings = warnings.select { |w| w.include?("avoided term") }
      expect(glossary_warnings).to be_empty
    end

    it "does not flag partial word matches — 'username' is not 'user'" do
      domain = build_domain do
        glossary do
          prefer "stakeholder", not: ["user"]
        end

        aggregate "Credential" do
          attribute :username, String
          command "CreateCredential" do
            attribute :username, String
          end
        end
      end

      _valid, _errors, warnings = validate(domain)
      glossary_warnings = warnings.select { |w| w.include?("avoided term") }
      expect(glossary_warnings).to be_empty
    end
  end

  describe "multiple banned terms" do
    it "flags all banned terms found in names" do
      domain = build_domain do
        glossary do
          prefer "stakeholder", not: ["user", "person"]
        end

        aggregate "PersonRecord" do
          attribute :name, String
          command "CreatePersonRecord" do
            attribute :name, String
          end
        end
      end

      _valid, _errors, warnings = validate(domain)
      expect(warnings).to include(a_string_matching(/contains avoided term 'person'/))
    end
  end

  describe "value objects and entities" do
    it "warns when value object name contains a banned term" do
      domain = build_domain do
        glossary do
          prefer "contact", not: ["user"]
        end

        aggregate "Profile" do
          attribute :name, String

          value_object "UserAddress" do
            attribute :street, String
          end

          command "CreateProfile" do
            attribute :name, String
          end
        end
      end

      _valid, _errors, warnings = validate(domain)
      expect(warnings).to include(a_string_matching(/ValueObject 'UserAddress' contains avoided term 'user'/))
    end

    it "warns when entity name contains a banned term" do
      domain = build_domain do
        glossary do
          prefer "contact", not: ["user"]
        end

        aggregate "Account" do
          attribute :name, String

          entity "UserRole" do
            attribute :title, String
          end

          command "CreateAccount" do
            attribute :name, String
          end
        end
      end

      _valid, _errors, warnings = validate(domain)
      expect(warnings).to include(a_string_matching(/Entity 'UserRole' contains avoided term 'user'/))
    end
  end
end
