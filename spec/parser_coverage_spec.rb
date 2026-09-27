require "spec_helper"
require "open3"

# Every (word, context) pair syntax.bluebook declares live must be either
# reported by `hecks-parse coverage` or listed, with a reason, in
# PENDING_PAIRS below — so the allowlist stays visible and only shrinks.

# `io: true` — the `cargo build` runs in `before(:context)`, not the
# `describe` body: RSpec still evaluates a group's top-level body while
# building the example tree even when `io: true` excludes every example
# in it, so tagging the group alone would not stop this from running.
RSpec.describe "the Rust parser's own coverage", :io do
  COVERAGE_RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
  COVERAGE_BINARY_PATH     = File.join(COVERAGE_RUST_PARSER_DIR, "target", "debug", "hecks-parse")

  def self.build_parser!
    built = system("cargo", "build", chdir: COVERAGE_RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{COVERAGE_BINARY_PATH}" unless File.executable?(COVERAGE_BINARY_PATH)
  end

  before(:context) { self.class.build_parser! }

  # Live means admitted or deprecated; proposed and retired words never
  # reach a generated parser table, the same rule every projection follows.
  def self.judged_meta
    Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
  end

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }
          .members.map { |row| row.to_h.transform_values(&:to_s) }
  end

  def self.status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s
  def self.live?(row) = %w[admitted deprecated].include?(status_of(row))

  # ADR 0026 — Keyword pairs come from SyntaxBoot.call, not rows("Keyword")
  # directly, since Keyword is dispatched through the entity lifecycle.
  DECLARED_PAIRS = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
                                                             .select { |row| live?(row) }.map do |row|
    [
      row[:word], row[:context]
    ]
  end.uniq.sort

  # What this parser builds is never restated here — only read off
  # `hecks-parse coverage`'s own printed set (confirmed byte-exact by
  # spec/parser_parity_spec.rb). A hand-kept copy here would make every
  # example below pass by construction, unable to catch drift.
  def self.reported_coverage
    stdout, status = Open3.capture2(COVERAGE_BINARY_PATH, "coverage")
    raise "hecks-parse coverage exited #{status.exitstatus}: #{stdout}" unless status.success?

    JSON.parse(stdout).map { |pair| [pair[0], pair[1]] }
  end

  # Delegates to the class method so instance-level examples can call it too.
  def reported_coverage = self.class.reported_coverage

  # PENDING_PAIRS is written out, not computed as `declared - reported`:
  # a computed list would silently absorb whatever the parser stops
  # building. This one is a partition — every declared pair is reported
  # or listed here, never both — and it only shrinks; a pair leaves the
  # moment `hecks-parse coverage` reports it.
  PENDING_PAIRS = [
    # Of the sibling grammars beside `MetaValidator::GRAMMAR_FILES`, `hecks-parse`
    # builds only `port`/`operation` and a PortOperation's `reference_to`/
    # `attribute`/`emits` (all reported); the rest is a parser stage of its own.
    ["a sibling grammar (world, hecksagon ports/adapters, data translation) hecks-parse does not build", [
      %w[adapter File], %w[aggregate Translation], %w[answers DomainPort], %w[answers Port],
      %w[answers PortOperation], %w[asks DomainPort], %w[backfill TranslationAggregate],
      %w[compute TranslationAggregate], %w[convert TranslationAggregate], %w[data_translation File],
      %w[default_adapter World], %w[default_database World], %w[drop TranslationAggregate],
      %w[field Adapter], %w[latest World], %w[move TranslationAggregate],
      %w[port Adapter], %w[port File], %w[realm World], %w[refuses PortOperation],
      %w[rekey TranslationAggregate], %w[rename TranslationAggregate], %w[retired Translation],
      %w[retype TranslationAggregate], %w[secret Adapter], %w[signal DomainPort], %w[signal Port],
      %w[subscribe Hecksagon], %w[tells DomainPort], %w[unresolved TranslationAggregate],
      %w[uses_embryonaut_bluebook Hecksagon], %w[uses_framework Hecksagon], %w[verb DomainPort],
      %w[verb Port], %w[world File]
    ]],
    # Declared query/read-model options no tracked corpus member happens to
    # use — `limit`/`where`/`order_by` are, and are reported.
    ["a query option no parity corpus member uses", [
      %w[authorize ReadModel], %w[cursor Query], %w[cursor ReadModel], %w[inspect_query Query],
      %w[inspect_query ReadModel], %w[nulls Query], %w[nulls ReadModel], %w[offset Query],
      %w[offset ReadModel]
    ]],
    # Checked against the whole corpus: each pair here appears in no tracked
    # parity bluebook (a nested `entity` inside an `entity`, for instance,
    # appears only in qa/stress_domains/nested_pieces, not a parity member).
    ["declared, and no parity corpus member exercises it", [
      %w[attaches_to Bluebook], %w[belongs_to Entity], %w[entity Entity], %w[formerly_known_as Bluebook],
      %w[has_many Aggregate], %w[has_many Entity], %w[has_one Aggregate], %w[has_one Entity],
      %w[provenance Command], %w[reference_to Entity], %w[reference_to Query], %w[state Command],
      %w[then_set Command]
    ]]
  ].freeze

  PENDING = PENDING_PAIRS.flat_map { |_reason, pairs| pairs }.freeze

  it "declares at least one (word, context) pair to hold the parser to" do
    expect(DECLARED_PAIRS).not_to be_empty
  end

  it "accounts for every declared pair as either reported-covered or explicitly pending" do
    unaccounted = DECLARED_PAIRS - reported_coverage - PENDING

    expect(unaccounted).to be_empty,
                           "these (word, context) pairs are neither reported by `hecks-parse coverage` nor in " \
                           "PENDING_PAIRS — syntax.bluebook grew a word, or the parser stopped reporting one: " \
                           "#{unaccounted.inspect}"
  end

  it "never lists as pending a pair the parser reports (the allowlist only shrinks)" do
    overlap = reported_coverage & PENDING

    expect(overlap).to be_empty,
                       "these pairs are BOTH reported as covered AND still pending — " \
                       "remove them from PENDING_PAIRS: #{overlap.inspect}"
  end

  it "never lists as pending a pair the grammar no longer declares" do
    stale = PENDING - DECLARED_PAIRS

    expect(stale).to be_empty, "PENDING_PAIRS names pairs syntax.bluebook no longer declares live: #{stale.inspect}"
  end

  # The other direction of the partition: a reported pair the grammar
  # does not declare live is a retired spelling still on COVERED_PAIRS.
  it "reports nothing the grammar does not declare" do
    undeclared = reported_coverage - DECLARED_PAIRS

    expect(undeclared).to be_empty,
                          "hecks-parse coverage reports pairs syntax.bluebook does not declare live — drop them " \
                          "from rust/parser/src/main.rs::COVERED_PAIRS: #{undeclared.inspect}"
  end

  it "keeps the allowlist itself sorted and duplicate-free (a real, reviewable list)" do
    expect(PENDING).to eq(PENDING.uniq)
    expect(PENDING_PAIRS.map(&:last)).to all(satisfy { |pairs| pairs == pairs.sort })
  end
end
