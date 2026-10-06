require "spec_helper"

RSpec.describe "relationship list runtime behavior" do
  RELATIONSHIP_RUNTIME_DOMAIN = proc do
    vision "relationships store and validate the identities they name"

    aggregate "Customer" do
      value_object("CustomerNumber") { attribute :value, String }
      identified_by CustomerNumber, as: :number

      command "Register" do
        role "Clerk"
        goal "Register a customer"
        attribute :number, CustomerNumber
      end
    end

    aggregate "Account" do
      value_object("AccountNumber") { attribute :value, String }
      identified_by AccountNumber, as: :number

      command "Open" do
        role "Clerk"
        goal "Open an account"
        attribute :number, AccountNumber
      end
    end

    aggregate "Portfolio" do
      value_object("PortfolioNumber") { attribute :value, String }
      identified_by PortfolioNumber, as: :number

      belongs_to Customer
      has_many Accounts

      command "Open" do
        role "Clerk"
        goal "Open a customer's portfolio"
        attribute :number, PortfolioNumber
        reference_to Customer, as: :customer
        attribute :accounts, list_of(String)
      end
    end
  end

  def boot_relationships
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("RelationshipRuntime", &RELATIONSHIP_RUNTIME_DOMAIN)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # A runtime holding customer c-1 and accounts a-1 and a-2.
  def runtime_with_customer_and_accounts
    runtime = boot_relationships
    runtime.dispatch_flat("RelationshipRuntime::Customer.Register", number: "c-1")
    runtime.dispatch_flat("RelationshipRuntime::Account.Open", number: "a-1")
    runtime.dispatch_flat("RelationshipRuntime::Account.Open", number: "a-2")
    runtime
  end

  def open_portfolio(runtime, number, accounts)
    runtime.dispatch_flat("RelationshipRuntime::Portfolio.Open", number: number, customer: "c-1", accounts: accounts)
  end

  def stored_portfolio(runtime, number)
    portfolio = runtime.registry.bluebook("RelationshipRuntime").aggregate("Portfolio")
    runtime.registry.repository("RelationshipRuntime", portfolio).find(number)
  end

  it "stores a has_many as a list" do
    runtime = runtime_with_customer_and_accounts
    open_portfolio(runtime, "p-1", %w[a-1 a-2])

    portfolio = stored_portfolio(runtime, "p-1")
    expect([portfolio[:customer], portfolio[:accounts]]).to eq(["c-1", %w[a-1 a-2]])
  end

  it "existence-checks every member of a has_many" do
    runtime = runtime_with_customer_and_accounts

    expect { open_portfolio(runtime, "p-2", %w[a-1 missing]) }
      .to raise_error(Hecks::Runtime::NotFound, /Account.*missing/)
  end

  it "refuses a scalar where has_many promises a list" do
    runtime = runtime_with_customer_and_accounts

    expect { open_portfolio(runtime, "p-1", "a-1") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /has_many relationship.*list of identities/)
  end
end
