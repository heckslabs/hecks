require "spec_helper"

# Real coverage for vocabulary.bluebook's registration of this
# session's new MutationOp/QueryComparator words: `multiply`/`clamp`/
# `remove` in MutationOp, `none_in_state` in QueryComparator.
#
# This closes a real, already-open test failure:
# `vocabulary_conformance_spec`'s `QueryComparator matches the table
# the runtime uses` (tracked as an expected gap since item 07/PR #27) --
# the self-hosted grammar's own `Vocabulary::QueryComparator` disagreed
# with `QuerySpecification::Common::Comparators::COMPARATORS` about
# whether `none_in_state` exists at all.
#
# HONEST partial result on the sibling MutationOp sign test: landing
# THIS PR does NOT fully close `vocabulary_conformance_spec`'s
# `MutationOp declares the same sign CommandRules::MUTATION_OPS
# computes with` -- that test now fails for a DIFFERENT, narrower
# reason (`remove` is declared in vocabulary.bluebook but the RUNTIME
# table, `CommandRules::Arithmetic::MUTATION_OPS`, doesn't have it
# yet -- a distinct bug, item 9045331/34 in this migration's own
# numbering, "THE RUNTIME TABLE bug, distinct from the DSL
# declaration"). Not claimed fixed here; that's the next item's job.
RSpec.describe "vocabulary.bluebook registers this session's new words" do
  def self.judged_meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.full_rows(name)
    aggregate = judged_meta.aggregates.find { |a| a.name == "Vocabulary" }
    aggregate.value_objects.find { |vo| vo.hecks_name == name }.members.map(&:to_h)
  end

  VOCAB_GROWTH_MUTATION_OP_ROWS = full_rows("MutationOp")
  VOCAB_GROWTH_QUERY_COMPARATOR_ROWS = full_rows("QueryComparator")

  it "MutationOp declares multiply/clamp/remove, all signless like set/append" do
    names = VOCAB_GROWTH_MUTATION_OP_ROWS.map { |row| row[:name] }
    expect(names).to include("multiply", "clamp", "remove")

    %w[multiply clamp remove].each do |name|
      row = VOCAB_GROWTH_MUTATION_OP_ROWS.find { |r| r[:name] == name }
      expect(row[:sign]).to eq(""), "#{name} should carry no sign, same reading as set/append"
    end
  end

  it "QueryComparator declares none_in_state" do
    names = VOCAB_GROWTH_QUERY_COMPARATOR_ROWS.map { |row| row[:name] }
    expect(names).to include("none_in_state")
  end

  it "QueryComparator now agrees with the runtime's own Comparators::COMPARATORS closed set" do
    declared = VOCAB_GROWTH_QUERY_COMPARATOR_ROWS.map { |row| row[:name] }
    runtime  = Hecks::QuerySpecification::Common::COMPARATORS.map(&:to_s)

    expect(declared).to match_array(runtime)
  end
end
