require "spec_helper"
require "tempfile"

# Query rows are `{ id: record.id }.merge(state)`; a declared attribute named `id`
# (BurningManPrep's Item) must not clobber the bare identity with its value object.
RSpec.describe "a query's own rows keep a declared :id attribute from clobbering the bare identity" do
  QUERY_INTERPRETER_THINGY_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Thingy" do
      aggregate "Thing" do
        identified_by :id

        value_object "ThingId" do
          attribute :value, String
        end

        value_object "ThingName" do
          attribute :value, String
        end

        attribute :id,   ThingId
        attribute :name, ThingName

        command "Mint" do
          attribute :id,   ThingId
          attribute :name, ThingName
          emits "Minted"
        end

        query "Everywhere" do
        end
      end
    end
  BLUEBOOK

  def declare_thingy(registry, path)
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(QUERY_INTERPRETER_THINGY_SOURCE, TOPLEVEL_BINDING, path, 1)

      Hecks.hecksagon("Thingy") do
        Thingy::Thing.persisted_by("Memory")
      end
    end
  end

  def bound_runtime(registry)
    registry.verify!
    runtime = Hecks::Runtime::Dispatcher.new(registry)
    Hecks::Runtime::Loader.bind_runtime(runtime)
    runtime
  end

  def boot
    registry = Hecks::Runtime::Registry.new
    file = Tempfile.new(["thing-", ".bluebook"])
    file.write(QUERY_INTERPRETER_THINGY_SOURCE)
    file.flush

    declare_thingy(registry, file.path)
    bound_runtime(registry)
  ensure
    file&.close!
  end

  def goggle_rows
    runtime = boot
    runtime.dispatch_flat("Thingy::Thing.Mint", id: { value: "t1" }, name: { value: "goggles" })
    runtime.query("Thingy::Thing.Everywhere")
  end

  it "returns a bare id, not the wrapped value object, off the in-memory query path", :aggregate_failures do
    rows = goggle_rows

    expect(rows.size).to eq(1)
    expect(rows.first[:id]).to eq("t1")
    expect(rows.first[:name]).to be_a(Hecks::Runtime::Value)
  end

  # `#cell` reads only `row[key.to_sym]`; an `||` fallback to the string key
  # would turn a stored `false` into nil.
  describe "#cell" do
    it "reads a stored false the same way it reads any other value", :aggregate_failures do
      interpreter = Hecks::Runtime::QueryInterpreter.new(nil)

      expect(interpreter.send(:cell, { active: false }, :active)).to be(false)
      expect(interpreter.send(:cell, { active: true }, :active)).to be(true)
    end
  end
end
