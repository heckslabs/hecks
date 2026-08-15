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
# `io: true` — a `cargo build` subprocess spawn is real I/O by this
# suite's own convention (see spec_helper.rb's `io: true` note). The build
# lives in a `before(:context)` hook, not the `describe` body, because
# RSpec still evaluates a group's top-level body while building the
# example tree even when `io: true` excludes every example in it —
# tagging the group alone doesn't stop plain body code from running.
RSpec.describe "the Rust parser's own coverage", io: true do
  COVERAGE_RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
  COVERAGE_BINARY_PATH     = File.join(COVERAGE_RUST_PARSER_DIR, "target", "debug", "hecks-parse")

  def self.build_parser!
    built = system("cargo", "build", chdir: COVERAGE_RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{COVERAGE_BINARY_PATH}" unless File.executable?(COVERAGE_BINARY_PATH)
  end

  before(:context) { self.class.build_parser! }

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

  # S14, ADR 0026 — Keyword is a genuine entity of Syntax now, dispatched
  # through a real lifecycle rather than merely declared — `SyntaxBoot.
  # call` hands back the same shape `rows("Keyword")` used to.
  DECLARED_PAIRS = Hecksagain::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
                     .select { |row| live?(row) }.map { |row| [row[:word], row[:context]] }.uniq.sort

  # EVERY (word, context) PAIR THIS PARSER GENUINELY BUILDS REAL IR FOR,
  # confirmed by `spec/parser_parity_spec.rb`'s byte-exact comparisons,
  # not just "the word gates cleanly." MUST match `rust/parser/src/
  # main.rs::COVERED_PAIRS` exactly — that's the literal source of what
  # `hecks-parse coverage` reports; a drift between the two lists is
  # exactly the unaccounted-pair failure below. STAGE 2 built the first
  # block (pizzas.bluebook, ~60% of the language surface in one file).
  # STAGE 3 added the block marked below. STAGE 4 (banking.bluebook —
  # entities, composite identity, process managers, read models with
  # every query option, `provenance`, a nested `policy`, `belongs_to`,
  # `on`'s blockless form — also confirmed by the concurrently-landed
  # `compliance`/`interview` real corpus members, which this stage's own
  # real construction work happened to fully cover too) adds the pairs
  # marked STAGE 4.
  COVERED_PAIRS = [
    %w[bluebook File], %w[hecksagon File],
    %w[vision Bluebook], %w[core Bluebook], %w[supporting Bluebook], %w[generic Bluebook],
    %w[aggregate Bluebook], %w[policy Bluebook],
    %w[process_manager Bluebook], # STAGE 4
    %w[description Aggregate], %w[identified_by Aggregate], %w[attribute Aggregate],
    %w[value_object Aggregate], %w[lifecycle Aggregate], %w[query Aggregate], %w[command Aggregate],
    %w[reference_to Aggregate], # STAGE 3
    %w[provenance Aggregate], %w[entity Aggregate], %w[policy Aggregate], %w[belongs_to Aggregate], # STAGE 4
    %w[description Entity], %w[identified_by Entity], %w[attribute Entity], # STAGE 4
    %w[command Entity], %w[query Entity], %w[lifecycle Entity], # STAGE 4
    %w[role Command], %w[goal Command], %w[reference_to Command], %w[given Command],
    %w[sets Command], %w[emits Command], %w[attribute Command],
    %w[ensures Command], # STAGE 4
    %w[attribute ValueObject], %w[one_of ValueObject], %w[invariant ValueObject],
    %w[member OneOf],
    %w[transition Lifecycle],
    %w[description Query], # STAGE 3
    %w[attribute Query], %w[where Query], %w[order_by Query],
    %w[limit Query], %w[authorize Query], # STAGE 4
    %w[on Policy], %w[trigger Policy],
    %w[across Policy], # STAGE 4
    %w[correlates_by ProcessManager], %w[starts_on ProcessManager], %w[ends_on ProcessManager], # STAGE 4
    %w[state ProcessManager], %w[on ProcessManager], # STAGE 4
    %w[dispatch Handler], # STAGE 4
    %w[port Hecksagon],
    %w[operation DomainPort],
    %w[reference_to PortOperation], %w[attribute PortOperation], %w[emits PortOperation],
    %w[read_model Bluebook], %w[description ReadModel], %w[include ReadModel], %w[group_by ReadModel], # STAGE 3
    %w[count ReadModel], %w[median ReadModel], # real, this session — banking.bluebook's own DisputedPaymentCount/Median
    %w[reference_to ReadModel], %w[where ReadModel], %w[order_by ReadModel], # STAGE 4
    %w[limit ReadModel], # STAGE 4
    %w[list_of Type], %w[one_of Type] # STAGE 6 — bookkeeping, not new dispatch work; see
    # `rust/parser/src/main.rs::COVERED_PAIRS`'s own header on why these
    # two were already built (Stage 2/3) but never added to either list
    # until Stage 6's own full-corpus audit found the gap.
  ].sort.freeze

  # THE ALLOWLIST — every (word, context) pair the language declares,
  # MINUS what this parser now genuinely builds (COVERED_PAIRS above).
  # Named per stage rather than left as one undifferentiated blob so a
  # future stage's own shrinkage is visible in the diff: Stage 4 removed
  # banking.bluebook's own slice, Stage 6 (the self-hosted grammar
  # itself — see `spec/parser_parity_spec.rb`'s own "bluebook_language"
  # member) closed a bookkeeping gap (`list_of`/`one_of` `Type`, real
  # since Stage 2/3 but never listed) and confirmed the rest is
  # GENUINELY unreached rather than merely unlisted.
  #
  # STILL NOT EMPTY, honestly, unlike the plan's own optimistic framing
  # ("PENDING_MEMBERS and the coverage allowlist are both empty at the
  # end of this stage") — every remaining pair was individually checked
  # against the WHOLE corpus (`grep`, not a guess) and confirmed to have
  # NO real usage anywhere to build against and byte-match: `has_many`/
  # `has_one` `Aggregate` (declared, sugar identical to the already-built
  # `belongs_to`/`has_one`, but no corpus member ever calls them —
  # `has_many` IS built anyway, see `parse::aggregate`'s own comment, but
  # stays off COVERED_PAIRS per this table's own rule: gated ≠ covered);
  # `reference_to` `Entity`/`Query` (a BARE, un-nested `reference_to`
  # directly inside an `entity`/`query` body — every real usage found is
  # nested inside a `command`, which is the `Command`-context row already
  # covered); `provenance` `Command` (the aggregate-level `provenance
  # from: {...}` keyword nested inside a `command` block — no corpus
  # member does this; `provenance` `Aggregate` IS covered, banking.bluebook's
  # own `Account`); `formerly_known_as` `Bluebook` (a domain rename IS
  # live in production per MEMORY — Embryonaut→EmbryonautFoundersApp —
  # but no `.bluebook` IN THIS CODEBASE'S OWN TRACKED CORPUS declares
  # one); `cursor`/`offset`/`nulls`/`inspect_query` `Query`/`ReadModel`
  # and `authorize` `ReadModel` (declared query/read-model options no
  # tracked corpus member happens to use — `limit`/`where`/`order_by`
  # are, and are covered; `consistency`/`freshness`/`use_index` are gone
  # entirely now, ADR 0025 — declared and parsed by nothing but the HTML
  # form renderer, so they failed the corpus-use-and-doctest bar);
  # `world` `File`, `latest`/`realm` `World`, `subscribe`/
  # `uses_framework` `Hecksagon`, `verb` `DomainPort` (the `World`/
  # `Hecksagon` SIBLING grammar files — `language/world.bluebook`/
  # `language/hecksagon.bluebook`, `MetaValidator::WORLD_GRAMMAR`/
  # `HECKSAGON_GRAMMAR` — are real but explicitly OUTSIDE this stage's
  # own scope, which named `MetaValidator::GRAMMAR_FILES`'s nine files
  # specifically; `hecks-parse resolve` for a real `.hecksagon` is also
  # still a Stage 1 stub, unrelated to this stage's own `chapter` work).
  # A future stage that wires up `.world`/`.hecksagon` parsing, or finds
  # a real corpus member exercising one of the others, is exactly what
  # would shrink this the rest of the way — fabricating coverage here
  # instead would be precisely the false claim this whole harness exists
  # to make impossible (this table's own opening comment).
  #
  # `where` `Policy` — new language surface (conditional policy
  # dispatch), same category as the rest of this list: declared for real
  # (PolicyBuilder answers it, PolicyInterpreter evaluates it), but no
  # corpus member `hecks-parse` actually parses (the nine self-hosted
  # grammar files, `pizzas`/`banking`/`compliance`, the framework trio,
  # `spec/fixtures/**`) declares one yet — the real dispatch coverage
  # lives in `spec/runtime/policy_spec.rb`'s own inline-built bluebooks,
  # which `hecks-parse` never sees. It is also the harder half: a `where`
  # is a BLOCK, where every arm `parse::policy` already builds reads a
  # positional text.
  #
  # `for_each` came OFF this list the way the paragraph above says one
  # should: `banking.bluebook`'s own `FreezeAccountsOnSuspension` became
  # the real corpus member exercising it (a suspension has to reach every
  # account the customer holds, and a policy with no fan-out could not
  # address one), and `parse::policy` grew the matching arm.
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
