require "spec_helper"
require_relative "support/read_model_spec_helpers"

# The Tally aggregate the repeated-reduction examples read, with two numeric fields to reduce.
REPEATED_REDUCTION_TALLY = proc do
  aggregate "Tally" do
    identified_by :ref
    attribute :ref, Ref
    attribute :units, Units
    attribute :hours, Hours
    { "Ref" => String, "Units" => Integer, "Hours" => Integer }
      .each { |name, type| value_object(name) { attribute :value, type } }
  end
end

# Each reduction line a Totals read model declares, as `[word, args...]`, paired with the refusal
# the build raises (`nil` when it builds).
REPEATED_REDUCTION_CASES = {
  "a sum twice"        => [[[:sum, :units], [:sum, :hours]], /Totals declares sum twice \(sum :units, then sum :hours\)/],
  "a median twice"     => [[[:median, :units], [:median, :hours]], /declares median twice/],
  "a count twice"      => [[[:count], [:count]], /declares count twice \(count, then count\)/],
  "a percentile twice" => [[[:percentile, :units, { at: 0.9 }], [:percentile, :hours, { at: 0.5 }]],
                           /declares percentile twice \(percentile :units, then percentile :hours\)/],
  "two kinds"          => [[[:sum, :units], [:avg, :hours]], /declares both sum and avg/]
}.freeze

# A read model reports one reduction: a reduction word declared twice is refused by name,
# rather than the later declaration replacing the earlier one unseen.
RSpec.describe "a read model that repeats a reduction" do
  include ReadModelSpecHelpers

  def totals_build(lines)
    domain_build("RepeatedReduction", proc do
      instance_exec(&REPEATED_REDUCTION_TALLY)
      read_model("Totals") do
        include Tally

        lines.each { |(word, *args)| send(word, *args.grep_v(Hash), **args.grep(Hash).reduce({}, :merge)) }
      end
    end)
  end

  REPEATED_REDUCTION_CASES.each do |label, (lines, message)|
    it "refuses #{label}, by name" do
      expect(&totals_build(lines)).to raise_error(Hecks::Bluebook::DSL::Malformed, message)
    end
  end

  it "builds a read model with one reduction" do
    expect(&totals_build([[:sum, :units]])).not_to raise_error
  end
end
