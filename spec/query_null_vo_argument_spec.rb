require "spec_helper"
require "hecks/fuzzing"

# A null value-object query argument is refused with TypeMismatch, not absorbed via field
# defaults (Value::Coercion#nil_argument). Only the refusal kind must match Rust, not the prose.
RSpec.describe "a null required value-object-typed query argument (QualityControl BUG#36)" do
  describe "LeaseClock::Lease.Expired (single-field value object, WITH a default)" do
    let(:domain) { File.join(InMemoryDomain::ROOT, "qa/stress_domains/lease_clock") }
    let(:result) do
      Hecks::Fuzzing::Replay.call(domain, [{ "query" => "LeaseClock::Lease.Expired", "args" => { "now" => nil } }])
    end

    it "refuses TypeMismatch instead of silently answering an empty list" do
      refusal = result[:refusals].find { |r| r[:verb] == "LeaseClock::Lease.Expired" }

      expect(refusal).to include(kind: "Hecks::Runtime::TypeMismatch", error: "LeaseInstant.value expects Integer, got nil")
    end

    # The query log entry carries the same refusal, not an empty row set.
    it "carries the same refusal on the query log entry" do
      query_entry = result[:queries].find { |q| q[:query] == "LeaseClock::Lease.Expired" }

      expect(query_entry[:error]).to eq("LeaseInstant.value expects Integer, got nil")
    end
  end

  describe "Banking::Account queries (multi-field value object, all fields defaulted)" do
    def boot
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
        Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
      end
    end

    let(:runtime) { @runtime ||= boot }

    %w[Overdrawn HighBalance StrictlyAbove AtMost].each do |query_name|
      it "#{query_name} refuses TypeMismatch on a null argument, never a silent empty list" do
        argument_name = query_name == "AtMost" ? :cap : :floor

        expect { runtime.query("Banking::Account.#{query_name}", argument_name => nil) }
          .to raise_error(Hecks::Runtime::TypeMismatch, "#{argument_name} is a Money — pass its fields as an object, not nil")
      end
    end
  end

  describe "Order.CostingLessThan (single-field value object, NO default — already correct, unaffected)" do
    let(:runtime) { @runtime ||= boot_in_memory }

    it "still refuses TypeMismatch on a null ceiling, exactly as before this fix" do
      expect { runtime.query("Pizzas::Order.CostingLessThan", ceiling: nil) }
        .to raise_error(Hecks::Runtime::TypeMismatch, "Price.cents expects Integer, got nil")
    end
  end
end
