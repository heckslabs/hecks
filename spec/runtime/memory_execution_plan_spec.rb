require "spec_helper"

RSpec.describe "Memory execution-plan capabilities" do
  def boot_inventory
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
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
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

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

    # A SECOND CREATION IS NOT A FRESH ONE. `Register` is a creating command
    # (no reference_to — nothing to act on yet), so a second dispatch at the
    # same identity refuses instead of silently replacing what the first one
    # wrote — the adapter's own `insert_only:` conflict check decides this
    # atomically (still zero `find` calls below: the conflict check reuses
    # the adapter's own native existence check, never the interpreter
    # reading the record first to ask).
    expect {
      runtime.dispatch(
        "Inventory::Item.Register",
        with: { sku: "sku-1", label: { value: "Second" } }
      )
    }.to raise_error(Hecksagain::Runtime::AlreadyExists, /Register creates a Item that already exists/)
    expect(finds).to eq(0)
    expect(repository.find("sku-1").state[:label].to_h).to eq(value: "First")

    expect do
      runtime.dispatch(
        "Inventory::Item.Register",
        to:   "sku-1",
        with: { sku: "sku-2", label: { value: "Wrong receiver" } }
      )
    end.to raise_error(Hecksagain::Runtime::TypeMismatch, /routes to "sku-1".*identity facts name "sku-2"/)
  end
end
