require "spec_helper"

RSpec.describe "lexical parent state and explicit disambiguation" do
  VISIBILITY_DOMAIN = proc do
    vision "commands read parent facts without repeating them as inputs"

    aggregate "Meter" do
      value_object("MeterCode") { attribute :value, String }
      value_object("Reading") { attribute :value, Integer }
      identified_by MeterCode, as: :code
      attribute :reading, Reading

      command "Install" do
        attribute :code, MeterCode
        attribute :reading, Reading
        sets :code
        sets :reading
      end

      command "RaiseReading" do
        attribute :reading, Reading
        given("the new reading is higher") { parent.reading.value < reading.value }
        sets :reading
      end
    end
  end

  def boot_meter
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Visibility", &VISIBILITY_DOMAIN)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_meter }

  def raise_reading(value)
    runtime.dispatch("Visibility::Meter.RaiseReading", to: "m-1", with: { reading: { value: value } })
  end

  before { runtime.dispatch("Visibility::Meter.Install", with: { code: "m-1", reading: { value: 10 } }) }

  it "lets a payload name shadow parent state while parent. remains explicit", :aggregate_failures do
    result = raise_reading(12)

    expect(result.state[:reading].to_h).to eq(value: 12)
    expect(result.execution_plan.payload_read_set).to include(:reading)
    expect(result.execution_plan.read_set).to include(:reading)
  end

  it "still reads the parent's reading through an explicit parent. in a given" do
    expect { raise_reading(9) }.to raise_error(Hecks::Runtime::GivenNotMet, /new reading is higher/)
  end
end
