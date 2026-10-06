require "spec_helper"

RSpec.describe "Memory execution-plan capabilities" do
  INVENTORY_DOMAIN = proc do
    vision "complete facts can be put without first loading a record"

    aggregate "Item" do
      value_object("Sku") { attribute :value, String }
      value_object("Label") { attribute :value, String }
      identified_by Sku, as: :sku
      attribute :label, Label

      command "Register" do
        attribute :sku, Sku
        attribute :label, Label
        sets :sku
        sets :label
      end
    end
  end

  def boot_inventory
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Inventory", &INVENTORY_DOMAIN)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_inventory }
  let(:finds) { [] }

  # One shared `finds` log across the dispatches proves atomic put never falls back to a read.
  let(:repository) do
    repo = runtime.registry.repository("Inventory", runtime.registry.bluebook("Inventory").aggregate("Item"))
    original_find = repo.method(:find)
    log = finds
    repo.define_singleton_method(:find) do |id|
      log << id
      original_find.call(id)
    end
    repo
  end

  def register(sku, label, **route)
    repository
    runtime.dispatch("Inventory::Item.Register", with: { sku: sku, label: { value: label } }, **route)
  end

  it "uses atomic put only after a complete-state proof, without ever reading", :aggregate_failures do
    inserted = register("sku-1", "First")

    expect(finds).to be_empty
    expect(inserted.execution_plan).to be_state_independent
  end

  it "reports the outcome of an atomic put as an insert" do
    expect(register("sku-1", "First").persistence_outcome.status).to eq(:inserted)
  end

  # A second creation at the same identity refuses instead of replacing; the adapter's
  # `insert_only:` check decides it atomically, so `find` stays at zero.
  it "refuses a second creation at the same identity, leaving the first untouched", :aggregate_failures do
    register("sku-1", "First")

    expect { register("sku-1", "Second") }
      .to raise_error(Hecks::Runtime::AlreadyExists, /Register creates a Item that already exists/)
    expect(finds).to be_empty
    expect(repository.find("sku-1").state[:label].to_h).to eq(value: "First")
  end

  it "refuses a creation routed to a different identity than its own facts name" do
    register("sku-1", "First")

    expect { register("sku-2", "Wrong receiver", to: "sku-1") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /routes to "sku-1".*identity facts name "sku-2"/)
  end
end
