require "spec_helper"
require "open3"

# The automated answer to "is everything tagged for drift from Ruby's own
# grammar". `declared (word, context) pairs from syntax.bluebook` minus
# `hecks-parse coverage`'s own reported set must be empty — minus an
# explicit, reasoned, named allowlist for staged rollout. Stage 1 left the
# allowlist as basically everything (`hecks-parse coverage` reported `[]`
# — nothing built yet). Stage 2 shrunk it by exactly the pairs
# pizzas.bluebook actually exercises; stage 3 shrinks it further by the
# framework trio's own real usage. What the parser builds is read off
# `hecks-parse coverage` itself (`rust/parser/src/main.rs::COVERED_PAIRS`),
# never mirrored here. The point is the allowlist is
# visible and itemized, and it will shrink stage by stage as parse/*.rs and
# build/*.rs stop being stubs — never silently grow.
# `io: true` — a `cargo build` subprocess spawn is real I/O by this
# suite's own convention (see spec_helper.rb's `io: true` note). The build
# lives in a `before(:context)` hook, not the `describe` body, because
# RSpec still evaluates a group's top-level body while building the
# example tree even when `io: true` excludes every example in it —
# tagging the group alone doesn't stop plain body code from running.
RSpec.describe "the Rust parser's own coverage", :io do
  COVERAGE_RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
  COVERAGE_BINARY_PATH     = File.join(COVERAGE_RUST_PARSER_DIR, "target", "debug", "hecks-parse")

  def self.build_parser!
    built = system("cargo", "build", chdir: COVERAGE_RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{COVERAGE_BINARY_PATH}" unless File.executable?(COVERAGE_BINARY_PATH)
  end

  before(:context) { self.class.build_parser! }

  # The same `rows`/`live?` reading spec/syntax_conformance_spec.rb and
  # bin/project_parser_table both already use — the declared surface,
  # live words only (admitted/deprecated; proposed/retired words reach no
  # generated parser table at all, same as every other projection).
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

  # S14, ADR 0026 — Keyword is a genuine entity of Syntax now, dispatched
  # through a real lifecycle rather than merely declared — `SyntaxBoot.
  # call` hands back the same shape `rows("Keyword")` used to.
  DECLARED_PAIRS = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
                                                             .select { |row| live?(row) }.map do |row|
    [
      row[:word], row[:context]
    ]
  end.uniq.sort

  # What this parser genuinely builds is not restated here. The one list is
  # `rust/parser/src/main.rs::COVERED_PAIRS` (pairs confirmed by
  # `spec/parser_parity_spec.rb`'s byte-exact comparisons, not just "the
  # word gates cleanly"), and `hecks-parse coverage` prints it — so this
  # reads the printed set. A Ruby copy used to sit here "kept in sync by
  # hand", which made `PENDING_PAIRS = DECLARED_PAIRS - COVERED_PAIRS`
  # true by construction: every example below that used it could not fail.
  def self.reported_coverage
    stdout, status = Open3.capture2(COVERAGE_BINARY_PATH, "coverage")
    raise "hecks-parse coverage exited #{status.exitstatus}: #{stdout}" unless status.success?

    JSON.parse(stdout).map { |pair| [pair[0], pair[1]] }
  end

  # The same class-level reading, reachable from inside an example — same
  # pattern spec/syntax_conformance_spec.rb's own `meta`/`self.judged_meta`
  # pairing already uses.
  def reported_coverage = self.class.reported_coverage

  # **The allowlist** — every declared pair this parser does not report, each
  # under the reason it is not built. Written out rather than computed as
  # "declared minus reported": a computed allowlist absorbs whatever the
  # parser stops building, and absorbs every new word the grammar grows,
  # without a line of diff. This one is a partition: every declared pair is
  # reported or listed here, never both, and a listed pair the grammar no
  # longer declares is stale. It only shrinks — a pair leaves the moment
  # `hecks-parse coverage` reports it, and the spec says so.
  PENDING_PAIRS = [
    # The sibling grammars beside the nine `MetaValidator::GRAMMAR_FILES`
    # this parser was staged against — `.world`, the hecksagon's ports and
    # adapters, and data translations. Of these `hecks-parse` builds only
    # `port`/`operation` and a PortOperation's `reference_to`/`attribute`/
    # `emits`, all reported. Wiring the rest is a parser stage of its own.
    ["a sibling grammar (world, hecksagon ports/adapters, data translation) hecks-parse does not build", [
      %w[adapter File], %w[aggregate Translation], %w[answers DomainPort], %w[answers Port],
      %w[answers PortOperation], %w[asks DomainPort], %w[backfill TranslationAggregate],
      %w[compute TranslationAggregate], %w[convert TranslationAggregate], %w[data_translation File],
      %w[drop TranslationAggregate], %w[field Adapter], %w[latest World], %w[move TranslationAggregate],
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
    # Checked against the whole corpus at Stage 6: `has_many`/`has_one`
    # `Aggregate` (sugar beside the reported `belongs_to`; `has_many` is
    # even parsed, but gated is not covered); a bare `reference_to` directly
    # in an `entity`/`query` body (every real one sits in a `command`);
    # `provenance` inside a `command`; `formerly_known_as` (no tracked
    # `.bluebook` declares a rename). The 2026-09-14 audit checked the
    # remaining unreasoned pairs in context: `attaches_to`, an `entity`'s
    # own `belongs_to`/`has_many`/`has_one`, a command-level `state`, and the
    # retired `then_set` appear in no corpus bluebook; a nested `entity`
    # inside an `entity` appears only in qa/stress_domains/nested_pieces,
    # which is not a parity member. The other nine were already parsed and
    # byte-matched, and moved to main.rs::COVERED_PAIRS.
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

  # The other direction of the same partition: a pair the parser reports
  # that the grammar no longer declares live is a retired spelling still
  # listed on main.rs::COVERED_PAIRS (ProcessManager's `state`/`on`, before
  # `transition` replaced them, was exactly this).
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
