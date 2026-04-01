require "spec_helper"

RSpec.describe "Error handling" do
  describe "guard policy rejection" do
    let(:domain) do
      Hecks.domain "GuardTest" do
        aggregate "Pizza" do
          attribute :name, String
          attribute :admin, String

          command "CreatePizza" do
            attribute :name, String
            attribute :admin, String
            guarded_by "AdminOnly"
          end

          policy "AdminOnly" do |cmd|
            cmd.admin == "yes"
          end
        end
      end
    end

    before { Hecks.load(domain, force: true) }

    it "raises GuardRejected when guard returns false" do
      expect {
        Pizza.create(name: "Margherita", admin: "no")
      }.to raise_error(Hecks::GuardRejected, /AdminOnly rejected/)
    end

    it "allows command when guard returns true" do
      pizza = Pizza.create(name: "Margherita", admin: "yes")
      expect(pizza.name).to eq("Margherita")
    end
  end

  describe "domain validation errors" do
    it "formats multiple validation errors with for_domain" do
      errors = ["Aggregate 'Pizza' has no fields", "Command 'Create' missing event"]
      error = Hecks::ValidationError.for_domain(errors)
      expect(error.message).to include("Domain validation failed:")
      expect(error.message).to include("- Aggregate 'Pizza' has no fields")
    end

    it "raises ValidationError for invalid domains" do
      domain = Hecks.domain "BadDomain" do
        aggregate "Widget" do
          attribute :name, String
          # no commands — validation will fail
        end
      end

      expect {
        Hecks.load(domain, force: true)
      }.to raise_error(Hecks::ValidationError, /validation failed/)
    end
  end

  describe "DSL syntax errors" do
    it "wraps DSL errors with aggregate context" do
      expect {
        Hecks.domain "DslError" do
          aggregate "Widget" do
            nonexistent_method
          end
        end
      }.to raise_error(Hecks::ValidationError, /Error in aggregate 'Widget'/)
    end
  end

  describe "error hierarchy" do
    it "GuardRejected is a Hecks::Error" do
      expect(Hecks::GuardRejected.ancestors).to include(Hecks::Error)
    end

    it "ValidationError is a Hecks::Error" do
      expect(Hecks::ValidationError.ancestors).to include(Hecks::Error)
    end

    it "MigrationError is a Hecks::Error" do
      expect(Hecks::MigrationError.ancestors).to include(Hecks::Error)
    end

    it "DomainLoadError is a Hecks::Error" do
      expect(Hecks::DomainLoadError.ancestors).to include(Hecks::Error)
    end

    it "GateAccessDenied is a Hecks::Error" do
      expect(Hecks::GateAccessDenied.ancestors).to include(Hecks::Error)
    end
  end
end
