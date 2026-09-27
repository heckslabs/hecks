require "spec_helper"
require "hecks/fuzzing"
require "json"

# Argument-gate ordering: each row of the generated matrix (bin/argument_gate_matrix) violates
# two adjacent gates, and the earlier declared gate's refusal must win.
#
# Rows and expected refusals are recorded from Ruby, the oracle (ADR 0010); the Rust port
# is held to the same rows by spec/rust_conformance_spec.rb.
#
# Adjacent pairs suffice: ordering composes, and gates a command cannot violate are left out.
RSpec.describe "the argument-gate ordering matrix" do
  MATRIX = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/argument_gate_order/matrix.json"))).freeze

  # Pinned as a set so a regeneration that drops a pair fails instead of shrinking the matrix.
  COVERED_PAIRS = [
    %w[normalize_args hydrate],
    %w[normalize_args hydrate_parent],
    %w[normalize_args refuse_role_mismatch],
    %w[normalize_args resolve_references],
    %w[refuse_absent_arguments normalize_args],
    %w[refuse_absent_arguments refuse_role_mismatch],
    %w[refuse_role_mismatch hydrate],
    %w[refuse_role_mismatch hydrate_parent],
    %w[refuse_role_mismatch resolve_references],
    %w[refuse_unknown_arguments normalize_args],
    %w[refuse_unknown_arguments refuse_absent_arguments],
    %w[refuse_unknown_arguments refuse_role_mismatch],
    %w[resolve_references hydrate]
  ].freeze

  it "covers every declared pair, and only pairs the vocabulary really orders that way" do
    expect(MATRIX.fetch("rows").map { |row| row.fetch("pair") }.uniq.sort).to eq(COVERED_PAIRS.sort)
  end

  it "names, for every row, two steps the declared order really puts in that order" do
    MATRIX.fetch("rows").each do |row|
      order = MATRIX.fetch(row.fetch("kind") == "entity" ? "entity_order" : "aggregate_order")
      earlier, later = row.fetch("pair")
      expect(order.index(earlier)).to be < order.index(later),
                                      "#{row.fetch('verb')}: #{earlier} is not declared before #{later}"
    end
  end

  it "attributes every row's refusal to the EARLIER of its two violated steps" do
    MATRIX.fetch("rows").each do |row|
      expect(row.dig("expected", "refused_at")).to eq(row.fetch("pair").first),
                                                   "#{row.fetch('verb')} #{row.fetch('pair').inspect}"
    end
  end

  MATRIX.fetch("rows").group_by { |row| row.fetch("domain") }.each do |domain, rows|
    it "#{domain}: replays to exactly the recorded refusals, in order" do
      steps = rows.map do |row|
        step = { "verb" => row.fetch("verb") }
        step["role"] = row["role"] if row["role"]
        step["args"] = row.fetch("args")
        step
      end

      result = Hecks::Fuzzing::Replay.call(File.join(InMemoryDomain::ROOT, domain), steps)
      actual = result[:refusals].map { |r| { "kind" => r[:kind].to_s.split("::").last, "error" => r[:error] } }
      expected = rows.map { |row| { "kind" => row.dig("expected", "kind"), "error" => row.dig("expected", "error") } }

      expect(actual).to eq(expected)
    end
  end
end
