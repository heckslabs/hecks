require "spec_helper"
require "open3"

# THE AUTOMATED ANSWER TO "IS EVERYTHING TAGGED FOR DRIFT FROM RUBY'S OWN
# GRAMMAR". `declared (word, context) pairs from syntax.bluebook` minus
# `hecks-parse coverage`'s own reported set must be empty — minus an
# explicit, reasoned, NAMED allowlist for staged rollout. At Stage 1 the
# allowlist is basically everything (`hecks-parse coverage` reports `[]`,
# per that command's own header on why Stage 1 has nothing to honestly
# claim yet) — that's expected and correct. The point is the allowlist is
# VISIBLE and ITEMIZED, and it will shrink stage by stage as parse/*.rs and
# build/*.rs stop being stubs — never silently grow.
RSpec.describe "the Rust parser's own coverage" do
  COVERAGE_RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
  COVERAGE_BINARY_PATH     = File.join(COVERAGE_RUST_PARSER_DIR, "target", "debug", "hecks-parse")

  def self.build_parser!
    built = system("cargo", "build", chdir: COVERAGE_RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{COVERAGE_BINARY_PATH}" unless File.executable?(COVERAGE_BINARY_PATH)
  end

  build_parser!

  # THE SAME `rows`/`live?` READING spec/syntax_conformance_spec.rb and
  # bin/project_parser_table both already use — the declared surface,
  # LIVE words only (admitted/deprecated; proposed/retired words reach no
  # generated parser table at all, same as every other projection).
  def self.judged_meta
    Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
  end

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }
          .members.map { |row| row.to_h.transform_values(&:to_s) }
  end

  def self.status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s
  def self.live?(row) = %w[admitted deprecated].include?(status_of(row))

  DECLARED_PAIRS = rows("Keyword").select { |row| live?(row) }.map { |row| [row[:word], row[:context]] }.uniq.sort

  # STAGE 1'S OWN ALLOWLIST — every (word, context) pair the language
  # declares, none of it built yet (parse/*.rs stubs out before reaching
  # ir.rs/build/*.rs — see parse/mod.rs's own header). Named per stage
  # rather than left as one undifferentiated blob so a future stage's own
  # shrinkage is visible in the diff: Stage 2 removes pizzas.bluebook's
  # slice of this list, Stage 3 the framework trio's, and so on, ending
  # empty at Stage 6 per the plan.
  STAGE_1_PENDING = DECLARED_PAIRS.freeze

  def self.reported_coverage
    stdout, status = Open3.capture2(COVERAGE_BINARY_PATH, "coverage")
    raise "hecks-parse coverage exited #{status.exitstatus}: #{stdout}" unless status.success?

    JSON.parse(stdout).map { |pair| [pair[0], pair[1]] }
  end

  # The same class-level reading, reachable from inside an example — same
  # pattern spec/syntax_conformance_spec.rb's own `meta`/`self.judged_meta`
  # pairing already uses.
  def reported_coverage = self.class.reported_coverage

  it "declares at least one (word, context) pair to hold the parser to" do
    expect(DECLARED_PAIRS).not_to be_empty
  end

  it "reports coverage as a real, honest, currently-empty list — Stage 1 builds nothing yet" do
    expect(reported_coverage).to eq([]),
                                "hecks-parse coverage claimed real coverage at Stage 1 — " \
                                "parse/*.rs and build/*.rs must still be stubs everywhere; " \
                                "if a construct really is built now, shrink STAGE_1_PENDING " \
                                "in this spec to match, don't just let this pass silently"
  end

  it "accounts for every declared pair as either reported-covered or explicitly pending" do
    covered = reported_coverage
    unaccounted = DECLARED_PAIRS - covered - STAGE_1_PENDING

    expect(unaccounted).to be_empty,
                           "these (word, context) pairs are neither covered nor in the " \
                           "named Stage 1 allowlist — syntax.bluebook grew a word this " \
                           "spec doesn't know about yet: #{unaccounted.inspect}"
  end

  it "never claims coverage the allowlist doesn't also know about (no double-booking)" do
    covered = reported_coverage
    overlap = covered & STAGE_1_PENDING

    expect(overlap).to be_empty,
                       "these pairs are BOTH reported as covered AND still marked pending — " \
                       "shrink STAGE_1_PENDING for whichever ones are actually built: #{overlap.inspect}"
  end

  it "keeps the allowlist itself sorted and duplicate-free (a real, reviewable list)" do
    expect(STAGE_1_PENDING).to eq(STAGE_1_PENDING.uniq)
    expect(STAGE_1_PENDING).to eq(STAGE_1_PENDING.sort)
  end
end
