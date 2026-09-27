require "spec_helper"

RSpec.describe "Memory execution-plan capabilities" do
  def boot_inventory
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Inventory" do
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
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # One shared `finds` counter across three dispatches proves atomic put never falls back to a
  # read; splitting the example would lose the counter's continuity.
  # rubocop:disable-next RSpec/ExampleLength
  it "uses atomic put only after a complete-state proof and reports its outcome" do
    runtime = boot_inventory
    item = runtime.registry.bluebook("Inventory").aggregate("Item")
    repository = runtime.registry.repository("Inventory", item)
    finds = 0
    original_find = repository.method(:find)
    repository.define_singleton_method(:find) do |id|
      finds += 1
      original_find.call(id)
    end

    inserted = runtime.dispatch(
      "Inventory::Item.Register",
      with: { sku: "sku-1", label: { value: "First" } }
    )

    expect(finds).to eq(0)
    expect(inserted.execution_plan).to be_state_independent
    expect(inserted.persistence_outcome.status).to eq(:inserted)

    # A second creation at the same identity refuses instead of replacing; the adapter's
    # `insert_only:` check decides it atomically, so `find` stays at zero.
    expect do
      runtime.dispatch(
        "Inventory::Item.Register",
        with: { sku: "sku-1", label: { value: "Second" } }
      )
    end.to raise_error(Hecks::Runtime::AlreadyExists, /Register creates a Item that already exists/)
    expect(finds).to eq(0)
    expect(repository.find("sku-1").state[:label].to_h).to eq(value: "First")

    expect do
      runtime.dispatch(
        "Inventory::Item.Register",
        to:   "sku-1",
        with: { sku: "sku-2", label: { value: "Wrong receiver" } }
      )
    end.to raise_error(Hecks::Runtime::TypeMismatch, /routes to "sku-1".*identity facts name "sku-2"/)
  end
end
