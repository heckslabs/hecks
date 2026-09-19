require "spec_helper"
require "hecks/fuzzing"

# QualityControl BUG#36 — a null required value-object-typed query
# argument used to be silently absorbed via the type's own field
# defaults (`Value::Coercion#nil_argument`, shared — pre-fix — with the
# command argument door), answering `rows: []` instead of refusing,
# whenever every one of the value object's fields happened to have a
# default. Rust's generated `check_query_args` already refused
# `TypeMismatch` on an explicit null regardless of any default — this
# file pins the fix (`QueryInterpreter#null_vo_argument!`) on every
# query argument shape the corpus actually declares:
#
#   - `LeaseClock::Lease.Expired`'s `now` — a single-field `LeaseInstant`
#     with a default (`value, Integer, default: 0`). Differentially
#     verified byte-for-byte against the compiled `lease_clock`
#     conformance binary in spec/corpus/rust_conformance/
#     lease_clock_expired_null_now.json (`spec/rust_conformance_spec.rb`,
#     `:io`); re-checked here too, cargo-free, for fast local feedback.
#   - `Banking::Account.{Overdrawn,HighBalance,StrictlyAbove,AtMost}`'s
#     `floor`/`cap` — a multi-field `Money` (`cents`/`currency`, both
#     defaulted). No existing banking spec passed a null `floor`/`cap`
#     before this file (checked: `grep -rn "Overdrawn\|HighBalance\|
#     StrictlyAbove\|AtMost" spec/` turns up only real-valued calls), so
#     refusing here is a genuinely new behavior, not a spec update to an
#     old assertion — and the right call: it closes a real, live
#     Ruby/Rust divergence (BUG#36), not just a style preference. Ruby's
#     own refusal wording here ("`floor` is a `Money` — pass its fields
#     as an object, not nil", `RefusalWording::TEMPLATES`'s existing
#     `value_object_shape` template — the same one an ordinary
#     wrong-shaped, non-null argument for a multi-field value object
#     already gets) does not need to be byte-identical to Rust's own
#     hardcoded `"Money expects an object, got nil"` — only the refusal
#     kind has to agree (`TypeMismatch` on both sides), the same bar
#     `spec/rust_conformance_fuzz_spec.rb`'s own generated-sequence
#     comparison holds refusals to (C8.2: prose is not the contract).
#   - `Order.CostingLessThan`'s `ceiling` — a single-field `Price` with
#     no default. Already agreed between engines before this fix (the
#     no-default branch of `nil_argument`/`check_required_fields` was
#     never touched); pinned here as a non-regression check.
RSpec.describe "a null required value-object-typed query argument (QualityControl BUG#36)" do
  describe "LeaseClock::Lease.Expired (single-field value object, WITH a default)" do
    let(:domain) { File.join(InMemoryDomain::ROOT, "qa/stress_domains/lease_clock") }

    it "refuses TypeMismatch instead of silently answering an empty list" do
      steps = [{ "query" => "LeaseClock::Lease.Expired", "args" => { "now" => nil } }]
      result = Hecks::Fuzzing::Replay.call(domain, steps)

      refusal = result[:refusals].find { |r| r[:verb] == "LeaseClock::Lease.Expired" }
      expect(refusal).not_to be_nil
      expect(refusal[:kind]).to eq("Hecks::Runtime::TypeMismatch")
      expect(refusal[:error]).to eq("LeaseInstant.value expects Integer, got nil")

      # Never silently answered `rows: []` for the null argument — the
      # query's own log entry carries the same refusal, not a clean
      # (possibly empty) row set.
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
