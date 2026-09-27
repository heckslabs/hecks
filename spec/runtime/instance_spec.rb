require "spec_helper"
require "tempfile"

# A composite identity has no single head for `Instance#materialize_identity!` to fall back on.
# A creating command may receive the heads as addressing arguments without declaring or `sets`-ing
# them; they must still be materialized, or the record is addressed but persists them as nil.
RSpec.describe Hecks::Runtime::Instance do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["instance-composite-identity-", ".bluebook"])
    file.write(source)
    file.flush

    registry = Hecks::Runtime::Registry.new
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
        Hecks.hecksagon(hecksagon_name, &binds)
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  ensure
    file&.close!
  end

  COMPOSITE_IDENTITY_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "CompositeIdentityGrowth" do
      aggregate "Plot" do
        identified_by :row, :column

        value_object "Row" do
          attribute :value, Integer
        end

        value_object "Column" do
          attribute :value, Integer
        end

        attribute :row,    Row
        attribute :column, Column
        attribute :crop,   String

        # Deliberately does NOT declare `row`/`column` as its own
        # attributes, and does NOT `sets` them — the exact shape M17
        # names: the record's identity heads are never redeclared as
        # attributes on the creating command at all.
        command "PlantCrop" do
          attribute :crop, String
          sets :crop
          emits "CropPlanted"
        end
      end
    end
  BLUEBOOK

  def repository_for(runtime)
    aggregate = runtime.registry.bluebook("CompositeIdentityGrowth").aggregate("Plot")
    runtime.registry.repository("CompositeIdentityGrowth", aggregate)
  end

  def boot_composite_identity
    boot(COMPOSITE_IDENTITY_SOURCE, "CompositeIdentityGrowth") do
      CompositeIdentityGrowth::Plot.persisted_by("Memory")
    end
  end

  it "fills both composite identity heads from args, not nil, when the creating command never redeclares them" do
    runtime = boot_composite_identity

    runtime.dispatch_flat("CompositeIdentityGrowth::Plot.PlantCrop",
                          row: { value: 3 }, column: { value: 5 }, crop: "wheat")

    plot = repository_for(runtime).all.first
    expect(plot).not_to be_nil
    expect(plot[:row]).not_to be_nil
    expect(plot[:column]).not_to be_nil
    expect(plot[:row][:value]).to eq(3)
    expect(plot[:column][:value]).to eq(5)
    expect(plot[:crop]).to eq("wheat")
  end

  it "still lets a SECOND command address the same record by its composite identity" do
    runtime = boot_composite_identity
    runtime.dispatch_flat("CompositeIdentityGrowth::Plot.PlantCrop",
                          row: { value: 3 }, column: { value: 5 }, crop: "wheat")

    plot = repository_for(runtime).all.first
    expect(plot.id).to include("3").and include("5")
  end
end
