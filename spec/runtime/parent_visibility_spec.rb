require "spec_helper"

RSpec.describe "lexical parent state and explicit disambiguation" do
  def boot_meter
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Visibility" do
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
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  it "lets a payload name shadow parent state while parent. remains explicit" do
    runtime = boot_meter
    runtime.dispatch("Visibility::Meter.Install", with: { code: "m-1", reading: { value: 10 } })

    result = runtime.dispatch("Visibility::Meter.RaiseReading", to: "m-1", with: { reading: { value: 12 } })

    expect(result.state[:reading].to_h).to eq(value: 12)
    expect(result.execution_plan.payload_read_set).to include(:reading)
    expect(result.execution_plan.read_set).to include(:reading)

    expect do
      runtime.dispatch("Visibility::Meter.RaiseReading", to: "m-1", with: { reading: { value: 9 } })
    end.to raise_error(Hecksagain::Runtime::GivenNotMet, /new reading is higher/)
  end
end
