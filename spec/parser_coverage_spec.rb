require "spec_helper"
require "open3"

# THE AUTOMATED ANSWER TO "IS EVERYTHING TAGGED FOR DRIFT FROM RUBY'S OWN
# GRAMMAR". `declared (word, context) pairs from syntax.bluebook` minus
# `hecks-parse coverage`'s own reported set must be empty — minus an
# explicit, reasoned, NAMED allowlist for staged rollout. STAGE 1 left the
# allowlist as basically everything (`hecks-parse coverage` reported `[]`
# — nothing built yet). STAGE 2 shrunk it by exactly the pairs
# pizzas.bluebook actually exercises; STAGE 3 shrinks it further by the
# framework trio's own real usage (this parser now genuinely turns both
# into real IR — mirrors `rust/parser/src/main.rs::COVERED_PAIRS` — kept
# in sync by hand for now, the same "hand-mirrored, not generated" call
# canonical.rs's own header already makes for a table this small and
# stable; if it ever needs to grow past that it should become generated
# the same way keywords.rs itself is). The point is the allowlist is
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

  # EVERY (word, context) PAIR THIS PARSER GENUINELY BUILDS REAL IR FOR,
  # confirmed by `spec/parser_parity_spec.rb`'s byte-exact comparisons,
  # not just "the word gates cleanly." MUST match `rust/parser/src/
  # main.rs::COVERED_PAIRS` exactly — that's the literal source of what
  # `hecks-parse coverage` reports; a drift between the two lists is
  # exactly the unaccounted-pair failure below. STAGE 2 built the first
  # block (pizzas.bluebook, ~60% of the language surface in one file).
  # STAGE 3 adds the block marked below — the framework trio's own
  # multi-path `identified_by` (no NEW pair: `identified_by`/`Aggregate`
  # already covered its bare-TYPE form, now also covers its SOURCE/block
  # form), an aggregate-level `reference_to` (identity.bluebook's own
  # `ExternalIdentifier`), inline `one_of(...)` attribute types (no new
  # pair either — `one_of`/`Type` was already a live row, just not yet
  # exercised by any real corpus member), and `report`/`include`/
  # `group_by`/a `ReadModel`'s own `description`, plus `description` for
  # `Query`.
  COVERED_PAIRS = [
    %w[bluebook File], %w[hecksagon File],
    %w[vision Bluebook], %w[core Bluebook], %w[supporting Bluebook], %w[generic Bluebook],
    %w[aggregate Bluebook], %w[policy Bluebook],
    %w[description Aggregate], %w[identified_by Aggregate], %w[attribute Aggregate],
    %w[value_object Aggregate], %w[lifecycle Aggregate], %w[query Aggregate], %w[command Aggregate],
    %w[reference_to Aggregate], # STAGE 3
    %w[role Command], %w[goal Command], %w[reference_to Command], %w[given Command],
    %w[sets Command], %w[emits Command], %w[attribute Command],
    %w[attribute ValueObject], %w[one_of ValueObject], %w[invariant ValueObject],
    %w[member OneOf],
    %w[transition Lifecycle],
    %w[description Query], # STAGE 3
    %w[attribute Query], %w[where Query], %w[order_by Query],
    %w[on Policy], %w[trigger Policy],
    %w[port Hecksagon],
    %w[operation DomainPort],
    %w[reference_to PortOperation], %w[attribute PortOperation], %w[emits PortOperation],
    %w[report Bluebook], %w[description ReadModel], %w[include ReadModel], %w[group_by ReadModel] # STAGE 3
  ].sort.freeze

  # THE ALLOWLIST — every (word, context) pair the language declares,
  # MINUS what this parser now genuinely builds (COVERED_PAIRS above).
  # Named per stage rather than left as one undifferentiated blob so a
  # future stage's own shrinkage is visible in the diff: Stage 4 removes
  # banking.bluebook's own slice next, and so on, ending empty at Stage 6
  # per the plan.
  PENDING_PAIRS = (DECLARED_PAIRS - COVERED_PAIRS).freeze

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

  it "reports coverage matching exactly the pairs this parser genuinely builds (COVERED_PAIRS)" do
    expect(reported_coverage.sort).to eq(COVERED_PAIRS),
                                      "hecks-parse coverage drifted from this spec's own " \
                                      "COVERED_PAIRS list (rust/parser/src/main.rs::" \
                                      "COVERED_PAIRS is the source of truth on the Rust side) — " \
                                      "keep the two in sync by hand"
  end

  it "accounts for every declared pair as either reported-covered or explicitly pending" do
    covered = reported_coverage
    unaccounted = DECLARED_PAIRS - covered - PENDING_PAIRS

    expect(unaccounted).to be_empty,
                           "these (word, context) pairs are neither covered nor in the " \
                           "named pending allowlist — syntax.bluebook grew a word this " \
                           "spec doesn't know about yet: #{unaccounted.inspect}"
  end

  it "never claims coverage the allowlist doesn't also know about (no double-booking)" do
    covered = reported_coverage
    overlap = covered & PENDING_PAIRS

    expect(overlap).to be_empty,
                       "these pairs are BOTH reported as covered AND still marked pending — " \
                       "shrink PENDING_PAIRS for whichever ones are actually built: #{overlap.inspect}"
  end

  it "keeps the allowlist itself sorted and duplicate-free (a real, reviewable list)" do
    expect(PENDING_PAIRS).to eq(PENDING_PAIRS.uniq)
    expect(PENDING_PAIRS).to eq(PENDING_PAIRS.sort)
  end
end
