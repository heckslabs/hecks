require "spec_helper"

# Guards the grammar boot against O(N^2) save cost: every dispatch touching a nested entity
# re-saves its whole parent aggregate. Asserts a save count, which is deterministic on CI.
# Budgets sit above the measured ~6,300 total and ~5,300 busiest aggregate, leaving headroom.
RSpec.describe "grammar boot save budget" do
  # `@grammar_registry` is process-global and memoized; it is restored afterwards so the forced
  # rebuild stays invisible to other specs (ir_golden_spec.rb compares against the first boot).
  it "does not dispatch more saves than a generous budget while booting the language's own grammar" do
    original_registry = Hecks::Bluebook::MetaValidator.instance_variable_get(:@grammar_registry)
    original_ready_for = Hecks::Bluebook::MetaValidator.instance_variable_get(:@grammar_ready_for)
    # The verdict cache is reset too: otherwise a second grammar build in this process is
    # answered from cache with zero saves, and `busiest` comes back empty.
    original_verdicts = Hecks::Bluebook::MetaValidator.instance_variable_get(:@verdicts)

    total = 0
    busiest = Hash.new(0)
    # TracePoint rather than allow_any_instance_of (RSpec/AnyInstance);
    # `target:` scopes it to one method.
    tracer = TracePoint.new(:call) do |tp|
      total += 1
      aggregate = tp.self.aggregate
      busiest[aggregate.respond_to?(:name) ? aggregate.name.to_s : aggregate.to_s] += 1
    end

    begin
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@verdicts, nil)
      tracer.enable(target: Hecks::Ports::Persistence::AppendOnly.instance_method(:save)) do
        Hecks::Bluebook::MetaValidator.grammar_registry
      end
    ensure
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, original_registry)
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_ready_for, original_ready_for)
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@verdicts, original_verdicts)
    end

    expect(busiest).not_to be_empty
    expect(total).to be < 9_000
    expect(busiest.values.max).to be < 7_500
  end
end
