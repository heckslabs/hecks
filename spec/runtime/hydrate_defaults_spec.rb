require "spec_helper"

# Point 6 of the translation design: a newly-required field with no
# historical source is an ordinary bluebook `default:`, not a
# translation rule. `Instance#initialize` always filled defaults for a
# FRESH instance; loading existing state never ran that same fill, so a
# record written before the attribute existed hydrated to nil forever.
# The runtime now fills declared defaults on the hydrate path too.
RSpec.describe "hydrating stored state through declared defaults" do
  def aggregate_with_defaults
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Hydration") do
        aggregate("Account") do
          identified_by :standing

          attribute :balance, Money
          attribute :standing, Standing, default: { value: "good" }
          attribute :notes, list_of(Note)

          lifecycle :status, default: "open" do
            transition "Close" => "closed"
          end

          value_object("Money") { attribute :cents, Integer }
          value_object("Standing") { attribute :value, String }
          value_object("Note") { attribute :text, String }
        end
      end
    end
    registry.bluebook("Hydration").aggregate("Account")
  end

  it "fills a declared default the stored record predates" do
    instance = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate_with_defaults, id: "a1", state: { balance: { "cents" => 100 } }
    )

    expect(instance[:standing].to_h).to eq(value: "good")
    expect(instance[:notes]).to eq([])
    expect(instance[:status]).to eq("open")
  end

  it "never overwrites a stored value with a default" do
    instance = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate_with_defaults, id: "a1",
      state: { balance: { "cents" => 100 }, standing: { "value" => "delinquent" }, status: "closed" }
    )

    expect(instance[:standing][:value]).to eq("delinquent")
    expect(instance[:status]).to eq("closed")
  end

  it "leaves an attribute with no declared default exactly as stored — absent" do
    instance = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate_with_defaults, id: "a1", state: { standing: { "value" => "good" } }
    )

    expect(instance.key?(:balance)).to be(false)
  end
end
