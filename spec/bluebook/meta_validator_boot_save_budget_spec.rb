require "spec_helper"

# Guards the grammar boot against O(N^2) save cost: every dispatch touching a nested entity
# re-saves its whole parent aggregate. Asserts a save count, which is deterministic on CI.
# Budgets sit above the measured ~6,300 total and ~5,300 busiest aggregate, leaving headroom.
RSpec.describe "grammar boot save budget" do
  # `@grammar_registry` is process-global and memoized; it is restored afterwards so the forced
  # rebuild stays invisible to other specs (ir_golden_spec.rb compares against the first boot).
  # The verdict cache is reset too: otherwise a second grammar build in this process is
  # answered from cache with zero saves, and the busiest aggregate comes back empty.
  def with_fresh_grammar
    validator = Hecks::Bluebook::MetaValidator
    saved = %i[@grammar_registry @grammar_ready_for @verdicts].to_h { |ivar| [ivar, validator.instance_variable_get(ivar)] }
    validator.instance_variable_set(:@grammar_registry, nil)
    validator.instance_variable_set(:@verdicts, nil)
    yield
  ensure
    saved&.each { |ivar, value| validator.instance_variable_set(ivar, value) }
  end

  # @return [Hash{String => Integer}] how many saves each aggregate took while the grammar booted
  def saves_per_aggregate
    counts = Hash.new(0)
    # TracePoint rather than allow_any_instance_of (RSpec/AnyInstance);
    # `target:` scopes it to one method.
    tracer = TracePoint.new(:call) { |tp| counts[label_of(tp.self.aggregate)] += 1 }
    with_fresh_grammar do
      tracer.enable(target: Hecks::Ports::Persistence::AppendOnly.instance_method(:save)) do
        Hecks::Bluebook::MetaValidator.grammar_registry
      end
    end
    counts
  end

  def label_of(aggregate) = aggregate.respond_to?(:name) ? aggregate.name.to_s : aggregate.to_s

  it "does not dispatch more saves than a generous budget while booting the language's own grammar", :aggregate_failures do
    saves = saves_per_aggregate

    expect(saves).not_to be_empty
    expect(saves.values.sum).to be < 9_000
    expect(saves.values.max).to be < 7_500
  end
end
