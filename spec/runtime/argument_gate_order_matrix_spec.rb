require "spec_helper"
require "hecks/fuzzing"
require "hecks/tools/argument_gate_matrix"
require "json"

# Argument-gate ordering: each row of the generated matrix (hecks argument_gate_matrix) violates
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

  def declared_order(row) = MATRIX.fetch(row.fetch("kind") == "entity" ? "entity_order" : "aggregate_order")

  def replay_step(row)
    step = { "verb" => row.fetch("verb") }
    step["role"] = row["role"] if row["role"]
    step["args"] = row.fetch("args")
    step
  end

  def recorded_refusals(rows)
    rows.map { |row| { "kind" => row.dig("expected", "kind"), "error" => row.dig("expected", "error") } }
  end

  def replayed_refusals(domain, rows)
    result = Hecks::Fuzzing::Replay.call(File.join(InMemoryDomain::ROOT, domain), rows.map { |row| replay_step(row) })
    result[:refusals].map { |r| { "kind" => r[:kind].to_s.split("::").last, "error" => r[:error] } }
  end

  def expect_declared_before(row)
    order = declared_order(row)
    earlier, later = row.fetch("pair")
    expect(order.index(earlier)).to be < order.index(later),
                                    "#{row.fetch("verb")}: #{earlier} is not declared before #{later}"
  end

  it "names, for every row, two steps the declared order really puts in that order" do
    MATRIX.fetch("rows").each { |row| expect_declared_before(row) }
  end

  it "attributes every row's refusal to the EARLIER of its two violated steps" do
    MATRIX.fetch("rows").each do |row|
      expect(row.dig("expected", "refused_at")).to eq(row.fetch("pair").first),
                                                   "#{row.fetch("verb")} #{row.fetch("pair").inspect}"
    end
  end

  STALE = "the committed matrix is behind the bluebooks: run " \
          "exe/hecks ConformanceRun.argument_gate_matrix! --confirm --wait and review the rows it moves".freeze

  # JSON as the generator writes it, read back, so hashes compare the way the files do.
  def as_written(value) = JSON.parse(JSON.generate(value))

  # @return [Hash{String => Hash}] every committed Rust fixture of the matrix, by path, without the
  #   `expect` block seed_semantics_corpus freezes (spec/rust_conformance_spec.rb holds Rust to it)
  def committed_fixtures
    Dir[File.join(InMemoryDomain::ROOT, "spec/corpus/rust_conformance/argument_gate_order_*.json")].to_h do |path|
      [path.delete_prefix("#{InMemoryDomain::ROOT}/"), JSON.parse(File.read(path)).except("expect")]
    end
  end

  # @return [Hash] the matrix and the fixtures the generator writes from the bluebooks as they are
  def regenerated
    generator = Hecks::Tools::ArgumentGateMatrix
    kept, = generator.sweep(InMemoryDomain::ROOT)
    fixtures = kept.group_by { |row| row[:domain] }
                   .to_h { |domain, rows| [generator.fixture_path(domain), generator.fixture_for(domain, rows)] }
    { matrix: as_written(generator.matrix_for(kept)), fixtures: as_written(fixtures) }
  end

  it "is what the generator writes from today's bluebooks, fixtures included", :aggregate_failures do
    fresh = regenerated
    expect(fresh[:matrix]).to eq(MATRIX), STALE
    expect(fresh[:fixtures]).to eq(committed_fixtures), STALE
  end

  MATRIX.fetch("rows").group_by { |row| row.fetch("domain") }.each do |domain, rows|
    it "#{domain}: replays to exactly the recorded refusals, in order" do
      expect(replayed_refusals(domain, rows)).to eq(recorded_refusals(rows))
    end
  end
end
