require "spec_helper"
require "hecks/fuzzing"
require "json"

# The argument-gate ordering MATRIX (roadmap D2) — Ruby's half. One
# generated table (`bin/argument_gate_matrix`, spec/corpus/
# argument_gate_order/matrix.json) replaces the hand-written refusal-order
# fixtures that each pinned one pair of argument gates on one command
# shape. Every row is an input violating both steps of an adjacent pair of
# argument-gate steps; the refusal that wins must be the earlier declared
# step's.
#
# **Nothing here is hand-written**: the rows, their inputs and their expected
# refusals all come from running Ruby (docs/decisions/0010 — Ruby is the
# oracle), recorded with the step Ruby's own dispatch trace attributes the
# refusal to. This spec holds Ruby to its own recorded answers, so a
# change to a gate's wording, class or position shows up as a diff here
# rather than silently; `spec/corpus/rust_conformance/argument_gate_order_
# *.json` — the same rows as an ordinary conformance script — holds the
# Rust port to them through `spec/rust_conformance_spec.rb`.
#
# **Adjacent pairs are enough**. The matrix covers pairs that are adjacent in
# the declared order once the gates a given command cannot violate are
# left out (a command with no declared `role` cannot violate
# `refuse_role_mismatch`, so `normalize_args` and `resolve_references` are
# adjacent for it). Adjacency composes: `refuse_unknown_arguments` beating
# `hydrate` follows from unknown < absent, absent < normalize and
# normalize < hydrate, each of which is a covered pair — which is why the
# matrix retires `bug38_entity_command_unknown_argument_before_extract_id`
# and its siblings rather than restating each of them.
RSpec.describe "the argument-gate ordering matrix" do
  MATRIX = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/argument_gate_order/matrix.json"))).freeze

  # Every pair the MATRIX is expected to cover. Pinned as a set, not as
  # counts: a regeneration that drops a whole pair (a domain's command
  # losing its `role`, say, or a generated "valid" value starting to fail
  # a domain's own invariant) fails here instead of quietly shrinking the
  # matrix to the pairs that still happen to work.
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
