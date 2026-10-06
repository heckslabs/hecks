require "spec_helper"

# `namespace` names the module a chapter's constants install under (ADR 0080): the Hecks
# domain nests under `Hecks::Domain`, since its aggregates share names with the gem's modules.
RSpec.describe "a chapter's namespace" do
  def registry_with(&)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  def declare(name, nest: nil)
    registry_with do
      Hecks.bluebook name do
        namespace nest if nest
        aggregate "Widget" do
          identified_by :id
          attribute :id, Id
          value_object "Id" do
            attribute :value, String
            invariant("an id is present") { !value.to_s.empty? }
          end
          command "Make" do
            goal "make a widget"
            attribute :id, Id
            sets :id
            emits "Made"
          end
        end
      end
      Hecks.hecksagon(name) { persisted_by "Memory" }
    end
  end

  # RSpec restores the stubbed constant, and everything installed under it, after each example.
  before { stub_const("NsOuter", Module.new) }

  it "is carried on the chapter and its IR, nil when undeclared" do
    expect(declare("NsPlain").bluebook("NsPlain").to_h[:namespace]).to be_nil
    expect(declare("NsNested", nest: "NsOuter::Inner").bluebook("NsNested").to_h[:namespace]).to eq("NsOuter::Inner")
  end

  it "installs the chapter at its namespace, with its aggregates inside it and none at the top level" do
    registry = declare("NsNested", nest: "NsOuter::Inner")
    Hecks::Doors::RubyDoor.install(Hecks::Runtime::Dispatcher.new(registry))

    expect(NsOuter::Inner.const_defined?(:Widget, false)).to be true
    expect(Object.const_defined?(:NsNested, false)).to be false
    expect(NsOuter::Inner.aggregates).to eq(["Widget"])
  end

  it "refuses a chapter whose constants would land in the gem's own Hecks module" do
    expect { declare("Hecks") }.to raise_error(Hecks::Bluebook::DSL::Malformed, /gem's own Hecks module/)
  end

  it "builds a chapter named Hecks that nests itself elsewhere" do
    expect(declare("Hecks", nest: "Hecks::Domain").bluebook("Hecks").namespace).to eq("Hecks::Domain")
  end
end
