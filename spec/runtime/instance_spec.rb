require "spec_helper"
require "tempfile"

# M17 (docs/audits/2026-08-10-main-bug-audit.md,
# docs/audits/2026-08-11-bug-triage.md) — a COMPOSITE identity
# (`identified_by :row, :column`, more than one head) has no single
# `identified_by` for `Instance#materialize_identity!` to fall back to
# `:id` for (`Behaviour::Identified#derive_identity` sets it nil the
# moment there's more than one head). `refuse_unknown_arguments`
# (`command_interpreter/argument_gate.rb`) already treats every
# identity head as an implicit "addressing" argument, legal on ANY
# command whether or not that command redeclares it as its own
# attribute — so a creating command can legitimately receive `row`/
# `column` in its payload (enough for `Identity.of` to derive the
# record's id) without ever declaring them as command attributes or
# `sets`-ing them into state. Before this fix, that left both heads
# persisted as `nil`: the record was correctly ADDRESSED but did not
# know its own name.
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

  COMPOSITE_IDENTITY_SOURCE = <<~BLUEBOOK
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
      ::CompositeIdentityGrowth::Plot.persisted_by("Memory")
    end
  end

  it "fills both composite identity heads from args, not nil, when the creating command never redeclares them" do
    runtime = boot_composite_identity

    runtime.dispatch("CompositeIdentityGrowth::Plot.PlantCrop",
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
    runtime.dispatch("CompositeIdentityGrowth::Plot.PlantCrop",
                     row: { value: 3 }, column: { value: 5 }, crop: "wheat")

    plot = repository_for(runtime).all.first
    expect(plot.id).to include("3").and include("5")
  end
end
