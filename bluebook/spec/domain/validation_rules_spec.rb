require "spec_helper"

RSpec.describe "Validation Rules" do
  def validate(domain)
    v = Hecks::Validator.new(domain)
    [v.valid?, v.errors, v.warnings]
  end

  describe "Naming::CommandNaming" do
    it "accepts common verbs without custom config" do
      %w[Create Update Delete Remove Place Cancel Submit Approve].each do |verb|
        domain = Hecks.domain("Validation") { aggregate("Widget") { attribute :name, String; command("#{verb}Thing") { attribute :name, String } } }
        valid, errors = validate(domain)
        expect(valid).to be(true), "Expected '#{verb}Thing' to be valid but got: #{errors}"
      end
    end

    it "accepts WordNet-known verbs like Reconcile, Dispatch, Authorize" do
      %w[Reconcile Dispatch Authorize Synchronize Provision].each do |verb|
        domain = Hecks.domain("Validation") { aggregate("Widget") { attribute :name, String; command("#{verb}Thing") { attribute :name, String } } }
        valid, _ = validate(domain)
        expect(valid).to be(true), "Expected '#{verb}Thing' to be valid"
      end
    end

    it "rejects nouns as command prefixes" do
      domain = Hecks.domain("Validation") { aggregate("Widget") { attribute :name, String; command("PizzaData") { attribute :name, String } } }
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.first).to include("doesn't start with a verb")
    end

    it "error message tells user to add to verbs.txt" do
      domain = Hecks.domain("Validation") { aggregate("Widget") { attribute :name, String; command("YeetThing") { attribute :name, String } } }
      _, errors = validate(domain)
      expect(errors.first).to include("verbs.txt")
    end

    it "reads custom verbs from verbs.txt when source_path is set" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "verbs.txt"), "Yeet\n")
        File.write(File.join(dir, "PizzasBluebook"), 'Hecks.domain("Validation") { aggregate("Widget") { attribute :name, String; command("YeetThing") { attribute :name, String } } }')
        domain_file = File.join(dir, "PizzasBluebook")
        domain = eval(File.read(domain_file), nil, domain_file, 1)
        domain.source_path = File.join(dir, "PizzasBluebook")
        valid, _ = validate(domain)
        expect(valid).to be true
      end
    end
  end

  describe "Naming::NameCollisions" do
    it "rejects value object with same name as aggregate" do
      domain = Hecks.domain("Validation") do
        aggregate("Pizza") do
          attribute :name, String
          value_object("Pizza") { attribute :label, String }
          command("CreatePizza") { attribute :name, String }
        end
      end
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("collision") || e.include?("same name") }).to be true
    end
  end

  describe "References::ValidReferences" do
    it "exempts qualified cross-domain references from compile-time validation" do
      domain = Hecks.domain("Validation") do
        aggregate("Order") do
          attribute :name, String
          reference_to "Billing::Invoice"
          command("PlaceOrder") { attribute :name, String }
        end
      end
      valid, errors = validate(domain)
      expect(valid).to be(true), "Expected qualified ref to pass but got: #{errors}"
    end

    it "still rejects unknown unqualified references" do
      domain = Hecks.domain("Validation") do
        aggregate("Order") do
          attribute :name, String
          reference_to "Nonexistent"
          command("PlaceOrder") { attribute :name, String }
        end
      end
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("unknown aggregate") }).to be true
    end
  end

  describe "References::NoSelfReferences" do
    it "rejects aggregate referencing itself" do
      domain = Hecks.domain("Validation") do
        aggregate("Thing") { reference_to "Thing"; command("CreateThing") { attribute :name, String } }
      end
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.downcase.include?("self") }).to be true
    end
  end

  describe "References::NoBidirectionalReferences" do
    it "rejects A->B and B->A references" do
      domain = Hecks.domain("Validation") do
        aggregate("Pizza") { reference_to "Order"; command("CreatePizza") { attribute :name, String } }
        aggregate("Order") { reference_to "Pizza"; command("PlaceOrder") { reference_to "Pizza" } }
      end
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.downcase.include?("bidirectional") }).to be true
    end

    it "allows one-directional references" do
      domain = Hecks.domain("Validation") do
        aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String } }
        aggregate("Order") { reference_to "Pizza"; command("PlaceOrder") { reference_to "Pizza" } }
      end
      valid, _ = validate(domain)
      expect(valid).to be true
    end
  end

  describe "value objects can reference aggregates" do
    it "allows reference attributes in value objects" do
      domain = Hecks.domain("Validation") do
        aggregate("Pizza") do
          attribute :name, String
          value_object("Topping") { reference_to "Order" }
          command("CreatePizza") { attribute :name, String }
        end
        aggregate("Order") { attribute :qty, Integer; command("PlaceOrder") { attribute :qty, Integer } }
      end
      valid, _ = validate(domain)
      expect(valid).to be true
    end
  end

  describe "warns on attributes that look like foreign keys" do
    it "warns when _id String attribute could be reference_to" do
      domain = Hecks.domain("Validation") do
        aggregate("Order") do
          attribute :team_id, String
          command("CreateOrder") { attribute :name, String }
        end
      end
      _, _, warnings = validate(domain)
      expect(warnings.any? { |w| w.include?("team_id") && w.include?("reference_to") }).to be true
    end

    it "does not warn on non-String _id attributes" do
      domain = Hecks.domain("Validation") do
        aggregate("Order") do
          attribute :sort_id, Integer
          command("CreateOrder") { attribute :name, String }
        end
      end
      _, _, warnings = validate(domain)
      expect(warnings.none? { |w| w.include?("sort_id") }).to be true
    end
  end

  describe "no PII in identity" do
    it "rejects PII attributes in composed identity" do
      domain = Hecks.domain("Validation") do
        aggregate("User") do
          attribute :email, String, pii: true
          attribute :org, String
          identity :email, :org
          command("CreateUser") { attribute :email, String; attribute :org, String }
        end
      end
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.include?("PII") && e.include?("email") }).to be true
    end

    it "allows non-PII attributes in identity" do
      domain = Hecks.domain("Validation") do
        aggregate("TeamCycle") do
          attribute :team, String
          attribute :start_date, Date
          identity :team, :start_date
          command("CreateTeamCycle") { attribute :team, String }
        end
      end
      valid, _ = validate(domain)
      expect(valid).to be true
    end
  end

  describe "Structure::AggregatesHaveCommands" do
    it "rejects aggregate without commands" do
      domain = Hecks.domain("Validation") { aggregate("Thing") { attribute :name, String } }
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.any? { |e| e.downcase.include?("command") }).to be true
    end
  end

  describe "Structure::ValidPolicyTriggers" do
    it "rejects policy triggering nonexistent command" do
      domain = Hecks.domain("Validation") do
        aggregate("Task") { attribute :name, String; command("CreateTask") { attribute :name, String }; policy("React") { on "CreatedTask"; trigger "Nonexistent" } }
      end
      valid, errors = validate(domain)
      expect(valid).to be false
      expect(errors.first).to include("unknown command")
    end

    it "accepts policy triggering valid command" do
      domain = Hecks.domain("Validation") do
        aggregate("Task") do
          attribute :name, String
          command("CreateTask") { attribute :name, String }
          command("ProcessTask") { attribute :name, String }
          policy("React") { on "CreatedTask"; trigger "ProcessTask" }
        end
      end
      valid, _ = validate(domain)
      expect(valid).to be true
    end
  end

  describe "Structure::ValidPolicyEvents" do
    it "allows cross-domain events (not an error)" do
      domain = Hecks.domain("Validation") do
        aggregate("Task") { attribute :name, String; command("CreateTask") { attribute :name, String }; policy("React") { on "ExternalEvent"; trigger "CreateTask" } }
      end
      valid, _ = validate(domain)
      expect(valid).to be true
    end
  end
end
