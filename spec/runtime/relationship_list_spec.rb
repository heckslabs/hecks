require "spec_helper"

RSpec.describe "relationship list runtime behavior" do
  # One declarative `Hecks.bluebook` fixture, booted for this file's own
  # examples — the line count is the DSL's own shape (three aggregates,
  # their identities and one command each), not accidental sprawl.
  # Splitting it would only break the single `bluebook`/`with_registry`
  # block scope this fixture needs to be one coherent domain.
  # rubocop:disable-next Metrics/MethodLength
  def boot_relationships
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "RelationshipRuntime" do
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
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  it "stores a has_many as a list and existence-checks every member" do
    runtime = boot_relationships
    runtime.dispatch("RelationshipRuntime::Customer.Register", number: "c-1")
    runtime.dispatch("RelationshipRuntime::Account.Open", number: "a-1")
    runtime.dispatch("RelationshipRuntime::Account.Open", number: "a-2")

    runtime.dispatch(
      "RelationshipRuntime::Portfolio.Open",
      number:   "p-1",
      customer: "c-1",
      accounts: %w[a-1 a-2]
    )

    portfolio = runtime.registry.repository(
      "RelationshipRuntime",
      runtime.registry.bluebook("RelationshipRuntime").aggregate("Portfolio")
    ).find("p-1")

    expect(portfolio[:customer]).to eq("c-1")
    expect(portfolio[:accounts]).to eq(%w[a-1 a-2])

    expect do
      runtime.dispatch(
        "RelationshipRuntime::Portfolio.Open",
        number:   "p-2",
        customer: "c-1",
        accounts: %w[a-1 missing]
      )
    end.to raise_error(Hecks::Runtime::NotFound, /Account.*missing/)
  end

  it "refuses a scalar where has_many promises a list" do
    runtime = boot_relationships
    runtime.dispatch("RelationshipRuntime::Customer.Register", number: "c-1")
    runtime.dispatch("RelationshipRuntime::Account.Open", number: "a-1")

    expect do
      runtime.dispatch(
        "RelationshipRuntime::Portfolio.Open",
        number:   "p-1",
        customer: "c-1",
        accounts: "a-1"
      )
    end.to raise_error(Hecks::Runtime::TypeMismatch, /has_many relationship.*list of identities/)
  end
end
