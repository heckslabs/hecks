require "spec_helper"

RSpec.describe Hecks::ValidationRules::Naming::SafeIdentifierNames do
  Attr  = Hecks::DomainModel::Structure::Attribute
  Agg   = Hecks::DomainModel::Structure::Aggregate
  Cmd   = Hecks::DomainModel::Behavior::Command
  Dom   = Hecks::DomainModel::Structure::Domain
  Inv   = Hecks::DomainModel::Structure::Invariant

  def str_attr(name) = Attr.new(name: name, type: String)
  def create_cmd     = Cmd.new(name: "CreatePizza", attributes: [str_attr(:name)])

  def domain_with_agg(agg_name, **opts)
    Dom.new(name: "Pizzas", aggregates: [Agg.new(name: agg_name, commands: [create_cmd], **opts)])
  end

  def validate(domain)
    v = Hecks::Validator.new(domain)
    [v.valid?, v.errors]
  end

  describe "aggregate names" do
    it "rejects a name containing a backtick" do
      valid, errors = validate(domain_with_agg("Pizza`Danger"))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("Pizza`Danger") }).to be true
    end

    it "rejects a name containing a double quote" do
      valid, errors = validate(domain_with_agg('Pizza"Bad'))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?('Pizza"Bad') }).to be true
    end

    it "rejects a lowercase aggregate name" do
      valid, errors = validate(domain_with_agg("pizza"))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("pizza") && e.include?("aggregate") }).to be true
    end
  end

  describe "attribute names" do
    it "rejects an attribute name containing a semicolon" do
      valid, errors = validate(domain_with_agg("Pizza", attributes: [str_attr(:"bad;name")]))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("bad;name") }).to be true
    end

    it "rejects an attribute name starting with uppercase" do
      valid, errors = validate(domain_with_agg("Pizza", attributes: [str_attr(:BadName)]))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("BadName") }).to be true
    end
  end

  describe "domain names" do
    it "rejects a domain name containing a slash" do
      domain = Dom.new(name: "Bad/Domain", aggregates: [Agg.new(name: "Pizza", commands: [create_cmd])])
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("Bad/Domain") }).to be true
    end

    it "rejects a lowercase domain name" do
      domain = Dom.new(name: "pizzas", aggregates: [Agg.new(name: "Pizza", commands: [create_cmd])])
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("pizzas") && e.include?("domain") }).to be true
    end
  end

  describe "enum values" do
    it "rejects an enum value containing special characters" do
      enum_attr = Attr.new(name: :status, type: String, enum: ["active", "bad value!"])
      valid, errors = validate(domain_with_agg("Pizza", attributes: [enum_attr]))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("bad value!") }).to be true
    end
  end

  describe "invariant messages" do
    it "rejects a message containing a backtick" do
      inv = Inv.new(message: "name must not be `empty`")
      valid, errors = validate(domain_with_agg("Pizza", invariants: [inv]))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("backtick") && e.include?("Pizza") }).to be true
    end

    it "rejects a message with unbalanced double quotes" do
      inv = Inv.new(message: 'name must not be "empty')
      valid, errors = validate(domain_with_agg("Pizza", invariants: [inv]))
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("unbalanced double quotes") }).to be true
    end
  end

  describe "valid domain" do
    it "passes all checks for a well-formed domain" do
      domain = Hecks.domain("Pizzas") do
        aggregate("Pizza") do
          attribute :name, String
          attribute :status, String, enum: ["active", "archived"]
          command("CreatePizza") { attribute :name, String }
        end
      end
      valid, errors = validate(domain)
      expect(valid).to be(true), "Expected valid domain but got: #{errors}"
    end
  end
end
