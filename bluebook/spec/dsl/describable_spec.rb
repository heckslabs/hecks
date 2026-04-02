require "spec_helper"

RSpec.describe "Describable keyword" do
  describe "domain description" do
    it "stores description on the domain IR" do
      domain = Hecks.domain("Banking") do
        description "Core banking operations"
        aggregate("Account") { attribute :name, String; command("CreateAccount") { attribute :name, String } }
      end
      expect(domain.description).to eq("Core banking operations")
    end

    it "returns nil when no description is provided" do
      domain = Hecks.domain("Banking") do
        aggregate("Account") { attribute :name, String; command("CreateAccount") { attribute :name, String } }
      end
      expect(domain.description).to be_nil
    end
  end

  describe "aggregate description" do
    it "stores description via the description keyword inside the block" do
      domain = Hecks.domain("Banking") do
        aggregate("Account") do
          description "Manages customer funds and balances"
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.description).to eq("Manages customer funds and balances")
    end

    it "stores description via positional arg (backward compat)" do
      domain = Hecks.domain("Banking") do
        aggregate "Account", "Manages customer funds" do
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.description).to eq("Manages customer funds")
    end
  end

  describe "command description" do
    it "stores description on command IR" do
      domain = Hecks.domain("Banking") do
        aggregate("Account") do
          attribute :name, String
          command("CreateAccount") do
            description "Opens a new bank account"
            attribute :name, String
          end
        end
      end
      expect(domain.aggregates.first.commands.first.description).to eq("Opens a new bank account")
    end
  end

  describe "value object description" do
    it "stores description on value object IR" do
      domain = Hecks.domain("Banking") do
        aggregate("Account") do
          attribute :name, String
          value_object("Address") do
            description "Mailing address for statements"
            attribute :street, String
          end
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.value_objects.first.description).to eq("Mailing address for statements")
    end
  end

  describe "entity description" do
    it "stores description on entity IR" do
      domain = Hecks.domain("Banking") do
        aggregate("Account") do
          attribute :name, String
          entity("LedgerEntry") do
            description "Records a single financial transaction"
            attribute :amount, Float
          end
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.entities.first.description).to eq("Records a single financial transaction")
    end
  end

  describe "event description" do
    it "stores description on explicit event IR" do
      domain = Hecks.domain("Banking") do
        aggregate("Account") do
          attribute :name, String
          event("AccountOverdrawn") do
            description "Emitted when balance goes negative"
            attribute :amount, Float
          end
          command("CreateAccount") { attribute :name, String }
        end
      end
      event = domain.aggregates.first.events.find { |e| e.name == "AccountOverdrawn" }
      expect(event.description).to eq("Emitted when balance goes negative")
    end
  end

  describe "policy description" do
    it "stores description on policy IR" do
      domain = Hecks.domain("Banking") do
        aggregate("Account") do
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
          command("FlagSuspicious") { attribute :name, String }
          policy("FraudAlert") do
            description "Flags large withdrawals for review"
            on "CreatedAccount"
            trigger "FlagSuspicious"
          end
        end
      end
      expect(domain.aggregates.first.policies.first.description).to eq("Flags large withdrawals for review")
    end
  end

  describe "service description" do
    it "stores description on service IR" do
      domain = Hecks.domain("Banking") do
        service("TransferMoney") do
          description "Moves funds between two accounts"
          attribute :amount, Float
        end
        aggregate("Account") { attribute :name, String; command("CreateAccount") { attribute :name, String } }
      end
      expect(domain.services.first.description).to eq("Moves funds between two accounts")
    end
  end

  describe "workflow description" do
    it "stores description on workflow IR" do
      domain = Hecks.domain("Banking") do
        workflow("LoanApproval") do
          description "Multi-step loan evaluation process"
          step "ScoreLoan"
        end
        aggregate("Loan") { attribute :amount, Float; command("ScoreLoan") { attribute :amount, Float } }
      end
      expect(domain.workflows.first.description).to eq("Multi-step loan evaluation process")
    end
  end

  describe "read model description" do
    it "stores description on read model IR" do
      domain = Hecks.domain("Banking") do
        view("AccountBalance") do
          description "Running balance projection"
          project("CreatedAccount") { |event, state| state }
        end
        aggregate("Account") { attribute :name, String; command("CreateAccount") { attribute :name, String } }
      end
      expect(domain.views.first.description).to eq("Running balance projection")
    end
  end

  describe "DslSerializer round-trip" do
    it "preserves descriptions through serialize and eval" do
      domain = Hecks.domain("Banking") do
        description "Core banking operations"
        aggregate("Account", definition: "Manages customer funds") do
          attribute :name, String
          value_object("Address") do
            description "Mailing address"
            attribute :street, String
          end
          command("CreateAccount") do
            description "Opens a new account"
            attribute :name, String
          end
        end
      end

      source = Hecks::DslSerializer.new(domain).serialize
      expect(source).to include('description "Core banking operations"')
      expect(source).to include('definition: "Manages customer funds"')
      expect(source).to include('description "Mailing address"')
      expect(source).to include('description "Opens a new account"')

      restored = eval(source)
      expect(restored.description).to eq("Core banking operations")
      expect(restored.aggregates.first.description).to eq("Manages customer funds")
      expect(restored.aggregates.first.value_objects.first.description).to eq("Mailing address")
      expect(restored.aggregates.first.commands.first.description).to eq("Opens a new account")
    end
  end
end
