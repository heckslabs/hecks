require "spec_helper"
require "tempfile"

# `QueryInterpreter#call`/`#reference_call` build every returned row as
# `{ id: record.id }.merge(record.state)` (or `r.state` for `Instance` —
# the `interpret`/`reference_interpret` in-memory paths). Merging `state`
# LAST let a declared attribute literally named `id` (real corpus now:
# BurningManPrep's `Item`, `attribute :id, ItemId`) clobber the correctly
# bare `record.id` with that attribute's own wrapped value object — the
# exact bug `Facade::Handle#to_h` already had (see handle_spec.rb), just
# one layer over: a query's own rows never go through `Handle` at all,
# so fixing `to_h` alone didn't cover this path. Found live: BurningManPrep's
# own "Everywhere" query (`Item.Everywhere`) fed a table whose every row's
# `id` came back `{value: "..."}`, collapsing the frontend's id-keyed
# lookup down to one entry.
RSpec.describe "a query's own rows keep a declared :id attribute from clobbering the bare identity" do
  def boot
    registry = Hecks::Runtime::Registry.new
    source = <<~BLUEBOOK
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
    file = Tempfile.new(["thing-", ".bluebook"])
    file.write(source)
    file.flush

    runtime = nil
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)

      Hecks.hecksagon("Thingy") do
        ::Thingy::Thing.persisted_by("Memory")
      end
    end

    registry.verify!
    runtime = Hecks::Runtime::Dispatcher.new(registry)
    Hecks::Runtime::Loader.bind_runtime(runtime)
    runtime
  ensure
    file&.close!
  end

  it "returns a bare id, not the wrapped value object, off the in-memory query path" do
    runtime = boot
    runtime.dispatch("Thingy::Thing.Mint", id: { value: "t1" }, name: { value: "goggles" })

    rows = runtime.query("Thingy::Thing.Everywhere")

    expect(rows.size).to eq(1)
    expect(rows.first[:id]).to eq("t1")
    expect(rows.first[:name]).to be_a(Hecks::Runtime::Value)
  end
end
