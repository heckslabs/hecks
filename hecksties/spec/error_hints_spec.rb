require "spec_helper"

RSpec.describe "Validation error hints" do
  def validate(domain)
    v = Hecks::Validator.new(domain)
    [v.valid?, v.errors, v.warnings]
  end

  describe "aggregates without commands" do
    it "includes a hint suggesting a command" do
      domain = Hecks.domain("HintTest") { aggregate("Widget") { attribute :name, String } }
      _, errors = validate(domain)
      err = errors.find { |e| e.include?("no commands") }
      expect(err).to be_a(Hecks::ValidationRules::ValidationMessage)
      expect(err.hint).to include("command 'CreateWidget'")
    end
  end

  describe "commands without attributes" do
    it "includes a hint suggesting an attribute" do
      domain = Hecks.domain("HintTest") do
        aggregate("Widget") do
          attribute :name, String
          command("CreateWidget") {}
        end
      end
      _, errors = validate(domain)
      err = errors.find { |e| e.include?("no attributes") }
      expect(err.hint).to include("attribute :name")
    end
  end

  describe "unknown references" do
    it "lists available aggregates in the hint" do
      domain = Hecks.domain("HintTest") do
        aggregate("Order") { attribute :name, String; reference_to "Nonexistent"; command("PlaceOrder") { attribute :name, String } }
        aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String } }
      end
      _, errors = validate(domain)
      err = errors.find { |e| e.include?("unknown aggregate") }
      expect(err.hint).to include("Pizza")
    end
  end

  describe "ValidationError.for_domain" do
    it "includes fix hints in the formatted message" do
      msg = Hecks::ValidationRules::ValidationMessage.new("bad thing", hint: "do the fix")
      error = Hecks::ValidationError.for_domain([msg])
      expect(error.message).to include("bad thing")
      expect(error.message).to include("Fix: do the fix")
    end

    it "handles plain strings without hints" do
      error = Hecks::ValidationError.for_domain(["plain error"])
      expect(error.message).to include("plain error")
      expect(error.message).not_to include("Fix:")
    end
  end
end
