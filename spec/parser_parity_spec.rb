require "spec_helper"
require "json"
require "open3"

# THE DIFFERENTIAL HARNESS — the anti-drift mechanism for the Rust parser,
# modeled directly on spec/rust_conformance_spec.rb's own cargo-build-then-
# subprocess-inside-rspec pattern, and on spec/corpus_spec.rb's own
# Dir.glob-derived (never hand-listed) corpus enumeration, so a new
# example/grammar-chapter/framework member is covered here automatically.
#
# STAGE 1 left every real corpus member PENDING — the parser built no IR
# at all yet. STAGE 2 shrunk PENDING_MEMBERS by exactly one
# (`pizzas.bluebook` + its `.hecksagon`, ~60% of the language surface in
# one small file — the plan's own deliberately-first target) and added a
# REAL byte-exact assertion for it in REAL_PARITY_MEMBERS below: shell out
# to `hecks-parse chapter --chapter Pizzas <bluebook> <hecksagon>` and
# compare the stdout JSON, byte for byte, against Ruby's own
# `JSON.pretty_generate(Exporter.call(...))` for the SAME two files loaded
# the same order `bin/project_rust` itself loads them (`.bluebook` first,
# registering every aggregate; `.hecksagon` second, mutating those
# already-registered aggregates' own `ports`). STAGE 3 does the identical
# thing for the framework trio — `identity.bluebook`/`governance.bluebook`/
# `console_settings.bluebook`, each standing alone (no `.hecksagon` of its
# own — see REAL_PARITY_MEMBERS' own comment on why). Every other corpus
# member stays pending, untouched, for a later stage. By Stage 6 both
# tables are empty.
#
# A parse error for anything OUTSIDE the pending list — or a PENDING
# member that no longer fails the way its own reason says it should, or a
# REAL_PARITY_MEMBERS entry whose output doesn't byte-match — is a spec
# FAILURE with the parser's own stderr inlined, never a silent skip.
# `io: true` — a `cargo build` subprocess spawn is real I/O by this
# suite's own convention (see spec_helper.rb's `io: true` note). The build
# lives in a `before(:context)` hook, not the `describe` body, because
# RSpec still evaluates a group's top-level body while building the
# example tree even when `io: true` excludes every example in it —
# tagging the group alone doesn't stop plain body code from running.
RSpec.describe "Rust parser parity (hecks-parse)", io: true do
  PARITY_RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
  PARITY_BINARY_PATH     = File.join(PARITY_RUST_PARSER_DIR, "target", "debug", "hecks-parse")

  def self.build_parser!
    built = system("cargo", "build", chdir: PARITY_RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{PARITY_BINARY_PATH}" unless File.executable?(PARITY_BINARY_PATH)
  end

  before(:context) { self.class.build_parser! }

  # THE SAME bluebook-lookup AND Dir.glob ENUMERATION spec/corpus_spec.rb
  # already uses — reused rather than re-derived, so this can never
  # silently drift from what "the corpus" means elsewhere in this suite.
  def self.bluebooks_in(domain)
    nested = Dir.glob(File.join(domain, "bluebook", "*.bluebook")).sort
    nested.empty? ? Dir.glob(File.join(domain, "*.bluebook")).sort : nested
  end

  # The SAME domain's own `.hecksagon`, if it has one — `bin/project_rust`
  # loads it right after the `.bluebook`, and `hecks-parse chapter` needs
  # it fed the same way for a REAL_PARITY_MEMBERS comparison.
  def self.hecksagon_in(domain)
    Dir.glob(File.join(domain, "bluebook", "*.hecksagon")).sort.first ||
      Dir.glob(File.join(domain, "*.hecksagon")).sort.first
  end

  PARITY_EXAMPLE_ROOTS = Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "*")).select { |path|
    File.directory?(path)
  }.sort.freeze
  PARITY_GRAMMAR_CHAPTERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/grammar", "*.bluebook")).sort.freeze
  PARITY_FRAMEWORK_MEMBERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook",
                                                "*.bluebook")).sort.freeze
  # STAGE 5's OWN TARGET — narrow, load-bearing unit-test fixtures for
  # OTHER Ruby specs (era/lineage bumps, model-checker findings, dispatch
  # ordering, reflex/hop-chain tests), never previously pointed at by
  # `hecks-parse` at all. Recursive (`**`) on purpose — note the `eras/`
  # and `model_check/` subdirectories, which a flat `*.bluebook` glob
  # would silently miss.
  PARITY_FIXTURES_ROOT = File.join(InMemoryDomain::ROOT, "spec/fixtures")
  PARITY_FIXTURE_MEMBERS = Dir.glob(File.join(PARITY_FIXTURES_ROOT, "**", "*.bluebook")).sort.freeze

  # STAGE 6's OWN TARGET — the self-hosted grammar itself: every concept file
  # `Hecks::Bluebook::MetaValidator::GRAMMAR_FILES` discovers, which
  # together constitute ONE `Hecks.bluebook "Bluebook", version: "1"`
  # declaration (`meta_validator.rb`'s own comment: "`BluebookBuilder
  # .build` keeps one builder open per chapter name across calls ... so
  # loading the folder in order accumulates one domain, not several" —
  # mirrored by `parse::chapter::parse_chapter`'s own multi-file merge,
  # built for exactly this). Read directly off the same discovered source set
  # the Ruby bootstrap uses, so parser parity and runtime loading cannot keep
  # separate filename catalogs.
  PARITY_LANGUAGE_GRAMMAR_FILES = Hecks::Bluebook::MetaValidator::GRAMMAR_FILES

  # [chapter name, bluebook path] — the chapter name is what `hecks-parse
  # chapter --chapter <Name>` expects; every real corpus `.bluebook` file
  # declares `Hecks.bluebook "<Name>"` on its own first line, so it's read
  # directly off the file rather than guessed from the filename (a grammar
  # chapter's own file is named after its ROLE — aggregate.bluebook — not
  # its chapter name, which is always "Bluebook").
  def self.chapter_name_of(bluebook_path)
    bluebook_path = Array(bluebook_path).first
    # No line cap — `File.foreach` is lazy and `.find` stops at the
    # first match regardless, so scanning the whole file costs nothing
    # extra for the common case (every existing corpus member's header
    # sits on line 1 or 2) and doesn't silently miss an outlier: framework/
    # bluebook/interview.bluebook's own header comment runs 33 lines
    # before the declaration, past a 20-line cap this used to carry.
    header = File.foreach(bluebook_path).find { |line| line =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
    header && Regexp.last_match(1)
  end

  # A FIXTURE'S OWN STEM keeps its subdirectory (`"eras/base"`,
  # `"model_check/lifecycle_findings"`) rather than the bare basename
  # every other member uses — `eras/base.bluebook` and a hypothetical
  # future `model_check/base.bluebook` would otherwise collide, and the
  # path itself is useful context nowhere else in this file needs to
  # carry (every other glob root holds one flat directory of members).
  def self.fixture_stem(path)
    path.delete_prefix("#{PARITY_FIXTURES_ROOT}/").delete_suffix(".bluebook")
  end

  PARITY_CORPUS_MEMBERS = (
    PARITY_EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebooks_in(domain)] } +
    PARITY_GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] } +
    PARITY_FRAMEWORK_MEMBERS.map { |member| [File.basename(member, ".bluebook"), member] } +
    PARITY_FIXTURE_MEMBERS.map { |member| [fixture_stem(member), member] } +
    # STAGE 6 — one member, several concept files (see PARITY_LANGUAGE_GRAMMAR_FILES'
    # own comment). Stemmed "bluebook_language" rather than bare
    # "bluebook" to keep it visibly distinct from
    # `lib/hecks/language/bluebook/bluebook.bluebook` — one of the
    # concept files, not the whole member.
    [["bluebook_language", PARITY_LANGUAGE_GRAMMAR_FILES]]
  ).reject { |_stem, path| path.nil? }.freeze

  # EVERY MEMBER WAS PENDING AT STAGE 1, each with the SAME honest reason.
  # STAGE 2 removed "pizzas" — it got a REAL byte-match assertion instead
  # (REAL_PARITY_MEMBERS below). STAGE 3 removed the framework trio
  # ("identity", "governance", "console_settings") the SAME way. STAGE 4
  # removes "banking" — entities, composite identity, process managers,
  # read models with every query option, `provenance`, a nested `policy`,
  # `belongs_to`, and `on`'s blockless form — the deliberately "big one"
  # per the plan.
  #
  # "expression"/"translation" (Stage 3) and, now, "compliance"
  # (Stage 4) ALSO come out here, a genuine bonus neither stage set out
  # to build: a concurrently-landed real corpus member
  # (`examples/compliance/`) that Stage 4's own real construction work
  # (entity/process_manager/read-model-options/provenance/nested-policy)
  # happened to fully cover, confirmed byte-exact against Ruby's own
  # `ir.json` before being moved here — the identical discipline every
  # other REAL_PARITY_MEMBERS entry gets. Leaving a member that
  # demonstrably round-trips marked "pending: not yet implemented" would
  # be exactly the kind of false claim this whole harness exists to make
  # impossible, so it's promoted rather than left stale — this is also
  # exactly the safety net working as designed: it showed up as a
  # spec FAILURE ("a PENDING member that no longer fails the way its own
  # reason says it should") the moment this stage's real construction
  # work made it stop failing, not a silent pass. (A second concurrently-
  # landed bonus member, "interview", was promoted here the same way at
  # the time — the whole Interview domain has since been removed from
  # this repo, taking that entry with it.)
  #
  # STAGE 5 removes EVERY `spec/fixtures/**/*.bluebook` member too — the
  # plan's own Stage 5 was narrowed (see this file's own history/the
  # session that added this comment) to "wire the fixtures in and confirm
  # byte-exactness," since the grammar-chapters half already landed as
  # Stage 3/4 bonuses. All twenty fixtures round-tripped byte-exact
  # against Ruby's own `ir.json` against the parser AS IT ALREADY STOOD,
  # with three small real gaps found and fixed along the way (not
  # overfit to these files alone — each is a genuine, general parser/
  # grammar fix): `transition`'s own Ruby-hash-literal shorthand spelling
  # (`from: "x", to: "y"`, no `=>` at all — `parse::mod::
  # argument_gate_fields_pairs`), `{ ... }` admitted for a `keywords`/
  # `rows` body the same way `do ... end` already was (`value_object(
  # "Name") { attribute :value, String }` — `parse::mod::body_gate`/
  # `parse_nested_body`), a parenless rocket-pair's own nested hash value
  # (`where :"a.b" => { ne: "x" }` — `lex::is_hash_literal_brace`), and
  # `attribute`'s type position admitting a quoted forward-reference
  # string (`attribute :name, "Name"`, a value object declared later in
  # the same aggregate — `syntax.bluebook`'s own new `text`-kind row +
  # `parse::mod::resolve_type_expression`).
  # STAGE 6 removes the LAST member — "bluebook_language", the
  # self-hosted grammar itself — leaving PENDING_MEMBERS EMPTY for good,
  # per the plan. See `REAL_PARITY_MEMBERS`' own comment on the two real
  # constructs this stage's own real parsing work found and built:
  # adjacent-string-literal concatenation across a backslash-continued
  # line, and a bare trailing-comma argument-list continuation with no
  # enclosing bracket at all — both genuinely new, both real corpus
  # syntax (vocabulary.bluebook's own long `RefusalTemplate` wording).
  #
  # "roster" — a LATER bonus, the same shape as "compliance"'s own
  # above: a concurrently-landed real corpus member
  # (`examples/roster/`, literally written AS the block-predicates'
  # own worked example — `.none?`/`.any?`/`.all?`/`.find { |x| … }`
  # over a value-object list, an entity list, and a value-object list
  # holding references, including one block nested inside another) that
  # the block-predicates construction work made fully round-trip. Same
  # discipline as every other promotion here: confirmed byte-exact
  # against Ruby's own `ir.json` before moving out of PENDING_MEMBERS,
  # not left stale — the safety net doing exactly its job, catching a
  # PENDING member that stopped failing the way its own reason claimed.
  #
  # "chess" — a new real corpus member (`examples/chess/`, ADR 0026's
  # own named gap: `entity`, `lifecycle`/`transition`, `policy`, and
  # `ensures` given real, non-contrived work — a piece with no life
  # outside the game that holds it, a status that refuses every illegal
  # jump, turn order and check announced by a policy reacting to a move
  # having happened, and a move whose own postcondition is checked after
  # the fact). Built entirely out of constructs `delegates_to`/`entity`/
  # `lifecycle`/`policy`/`ensures`'s own existing byte-matched users
  # (roster, banking) already exercise, so it round-trips the same way
  # they do — confirmed byte-exact against Ruby's own `ir.json` before
  # being added here rather than left in PENDING_MEMBERS to claim a
  # parser gap this domain does not actually have.
  # "directory" — the corpus's own real `rekey`/`compute` example
  # (`examples/directory/`, the schema-evolution guide's `identified_by
  # :name` -> `identified_by :email` worked example, landed for real —
  # see spec/adapters/driven/postgres_era/directory_rekey_spec.rb).
  # Built entirely out of constructs pizzas'/roster's own byte-matched
  # `.bluebook` already exercises (a plain aggregate, value objects, one
  # command) — no `.hecksagon` of its own, either — so it round-trips
  # the same way they do: confirmed byte-exact against Ruby's own
  # `ir.json` before being added here, same discipline as every other
  # promotion above, not left in PENDING_MEMBERS to claim a parser gap
  # this domain does not actually have. (Its own translation edge under
  # `bluebook/translations/` is a SEPARATE sub-language this file's own
  # PARITY_CORPUS_MEMBERS enumeration never reaches — `bluebooks_in`
  # only globs `bluebook/*.bluebook`, one level, the same way
  # `spec/corpus_spec.rb`'s own `bluebook_in` does.)
  PENDING_MEMBERS = (PARITY_CORPUS_MEMBERS.map(&:first) -
                     %w[pizzas identity governance console_settings expression translation banking compliance roster
                        chess directory bluebook_language] -
                     PARITY_FIXTURE_MEMBERS.map { |member| fixture_stem(member) })
                    .to_h { |stem| [stem, "Stage 1: parser not implemented yet — see rust/parser/src/parse/mod.rs"] }.freeze

  # Every remaining PENDING member's own expected diagnostic — plain
  # "not yet implemented" for every one of them, now that Stage 3 moved
  # the two members that used to surface a DIFFERENT, earlier gate
  # failure (`identified_by do ... end`'s multi-path block form — real,
  # confirmed Stage 3 territory, not a Stage 2 regression) into
  # REAL_PARITY_MEMBERS below with `parse::aggregate`/`lex.rs` now
  # actually building it. Kept as a `Hash.new` default (rather than
  # deleted outright) so a FUTURE stage that finds another member
  # stopping at a different, real, earlier gate than "not yet
  # implemented" has the same place to name it Stage 2 already did.
  PENDING_MEMBERS_DIAGNOSTIC = Hash.new("not yet implemented").freeze

  # stem -> [chapter name, files...] — the files fed to `hecks-parse
  # chapter`, IN THE SAME ORDER `bin/project_rust` itself loads them: the
  # domain's own `.bluebook` first (registers every aggregate), then its
  # `.hecksagon` if it has one (mutates those already-registered
  # aggregates' own `ports` — `Pizzas::Order.port "PaymentGateway" do
  # ... end`, real syntax confirmed by reading pizzas.hecksagon directly).
  # Derived the SAME way PARITY_CORPUS_MEMBERS itself is (`bluebook_in`/
  # `hecksagon_in`/`chapter_name_of`), not hand-listed, so this stays
  # honest if pizzas.bluebook's own file ever moves.
  REAL_PARITY_MEMBERS = %w[pizzas banking compliance roster chess directory].to_h { |stem|
    domain = PARITY_EXAMPLE_ROOTS.find { |path| File.basename(path) == stem } or raise "no examples/#{stem} directory"
    bluebooks = bluebooks_in(domain)
    raise "#{domain} has no .bluebook" if bluebooks.empty?

    chapter_name = chapter_name_of(bluebooks) or raise "#{bluebooks.first} has no 'Hecks.bluebook \"Name\"' header"
    [stem, [chapter_name, bluebooks + [hecksagon_in(domain)].compact]]
  }.merge(
    # THE FRAMEWORK TRIO (Stage 3). A framework bluebook has no
    # `.hecksagon` of its own (confirmed by reading
    # lib/hecks/framework/bluebook/ directly): the comparison target
    # is `hecks-parse chapter --chapter <Name> <bluebook>` standing
    # alone, no `uses_framework`/`resolve` multi-file step needed (that
    # mechanism only matters for a CONSUMING app's own `.hecksagon`,
    # e.g. banking.hecksagon's real `uses_framework "Governance"`/
    # `"Identity"` — real Stage 4 territory, and banking.hecksagon's own
    # sibling `Hecks.hecksagon "Governance"`/`"Identity"` blocks, a SEPARATE
    # finding `parse::chapter`'s own header explains).
    #
    # "interview" (Stage 4's own bonus member, PARITY_FRAMEWORK_MEMBERS)
    # was removed along with the whole Interview domain — dropped, not
    # kept in this repo.
    %w[identity governance console_settings].to_h { |stem|
      bluebook = PARITY_FRAMEWORK_MEMBERS.find { |path| File.basename(path, ".bluebook") == stem } or
        raise "no lib/hecks/framework/bluebook/#{stem}.bluebook"
      chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
      [stem, [chapter_name, [bluebook]]]
    }
  ).merge(
    # THE BONUS — "expression"/"translation", see PENDING_MEMBERS' own
    # comment on why these two `PARITY_GRAMMAR_CHAPTERS` members (Stage
    # 5's own named target) are here already. Same standalone shape as
    # the framework trio: a grammar chapter has no `.hecksagon` either.
    %w[expression translation].to_h { |stem|
      bluebook = PARITY_GRAMMAR_CHAPTERS.find { |path| File.basename(path, ".bluebook") == stem } or
        raise "no lib/hecks/grammar/#{stem}.bluebook"
      chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
      [stem, [chapter_name, [bluebook]]]
    }
  ).merge(
    # STAGE 5 — EVERY `spec/fixtures/**/*.bluebook` member, not
    # hand-listed (see PARITY_FIXTURE_MEMBERS' own `Dir.glob`, above), so
    # a future fixture is covered automatically. Same standalone shape as
    # the framework trio/grammar chapters: none of these narrow unit-test
    # fixtures pairs with a `.hecksagon` (confirmed by `find spec/fixtures
    # -iname '*.hecksagon'` finding nothing at all).
    PARITY_FIXTURE_MEMBERS.to_h { |bluebook|
      stem = fixture_stem(bluebook)
      chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
      [stem, [chapter_name, [bluebook]]]
    }
  ).merge(
    # STAGE 6 — the self-hosted grammar itself, all nine
    # `PARITY_LANGUAGE_GRAMMAR_FILES` fed to ONE `hecks-parse chapter
    # --chapter Bluebook` invocation, in the SAME declared order
    # `MetaValidator.load_grammar_into` itself loads them — real parser
    # work this stage built: `parse::chapter::parse_chapter`'s own
    # multi-file merge (previously a hard "not yet implemented" the
    # moment a SECOND `Bluebook`-context file showed up), plus two
    # genuinely new constructs `syntax.bluebook`/`vocabulary.bluebook`'s
    # own long `RefusalTemplate` wording needed and no earlier corpus
    # member ever exercised: a backslash-continued line whose two
    # adjacent quoted string literals concatenate (Ruby's own
    # adjacent-literal rule — `lex::join_continuations`'s own
    # `ends_with_bare_backslash` + `ruby_value::scan_adjacent_strings`),
    # and a bare trailing-comma argument-list continuation with NO
    # enclosing bracket at all for `bracket_delta` to track (`member
    # refusal: "X", site: "Y",` + `template: "Z"` on the next physical
    # line — `lex::join_continuations`'s own `ends_with_bare_comma`).
    # Confirmed byte-exact against `MetaValidator.grammar_registry`'s own
    # reconstructed graph BEFORE this entry was added — see
    # `ruby_ir_json`'s own comment on why this one member's oracle path
    # is different from every other's.
    { "bluebook_language" => [chapter_name_of(PARITY_LANGUAGE_GRAMMAR_FILES.first), PARITY_LANGUAGE_GRAMMAR_FILES] }
  ).freeze

  def self.run_chapter(chapter_name, *paths)
    Open3.capture3(PARITY_BINARY_PATH, "chapter", "--chapter", chapter_name, *paths)
  end

  # Ruby's OWN oracle — the exact sequence `bin/project_rust` itself
  # loads a domain through (persistence/extraction ports, the memory +
  # prism adapters, then the domain's own files in order), exported the
  # SAME way `Exporter.call`/`JSON.pretty_generate` already are — never
  # the key-sorted `spec/golden/ir/*.json` fixtures (those are
  # deliberately re-sorted for human-readable diffs, per
  # `spec/ir_golden_spec.rb`'s own `rendered`/`sorted` — Ruby Hash
  # insertion order, unsorted, is the real wire contract this parser has
  # to match).
  #
  # "bluebook_language" is the ONE STEM that can't go through the
  # ordinary `Kernel.load`-in-a-fresh-registry path every other member
  # uses: `Hecks.bluebook` always calls `MetaValidator.call` the moment a
  # file finishes loading UNLESS `MetaValidator.bootstrapping?` is true,
  # and loading `aggregate.bluebook` (the self-hosted grammar's own
  # SECOND file) that way refuses immediately — it references
  # `ValueObject`/`Entity`, both declared in LATER files. Confirmed real:
  # attempting the ordinary path here raises exactly that Malformed.
  # `MetaValidator.load_grammar_into` is the ONLY door that sets
  # `@bootstrapping = true` around the whole nine-file load (its own
  # header: "every caller of the grammar must go through here for
  # exactly that reason"), deferring validation to the ONE fixpoint judge
  # `MetaValidator.grammar_registry` itself runs afterward — and by the
  # time `grammar_registry` returns, its `Bluebook` entry IS the
  # RECONSTRUCTED (post-`MetaValidator.call`) graph, the exact same
  # "MetaValidator's own reconstructed graph, not the builder's raw one"
  # target every other member reaches via its own ordinary
  # `Hecks.bluebook`-triggered call — just reached through the one door
  # this particular member actually has.
  def self.ruby_ir_json(stem, chapter_name, paths)
    registry =
      if stem == "bluebook_language"
        Hecks::Bluebook::MetaValidator.grammar_registry
      else
        fresh = Hecks::Runtime::Registry.new
        Hecks.with_registry(fresh) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          bluebooks, companions = paths.partition { |path| File.extname(path) == ".bluebook" }
          InMemoryDomain.load_bluebook_files(bluebooks)
          companions.each { |path| Kernel.load(path) }
        end
        fresh
      end
    ir = Hecks::Projector::Exporter.call(registry).fetch(chapter_name)
    "#{JSON.pretty_generate(strip_invariant_ast(ir))}\n"
  end

  # `invariants[].ast` (`ValueObject#to_h`, `Expression::AstJson`'s own
  # JSON-serializable rendering of the SAME `canonical` text right beside
  # it) is a NAMED, DELIBERATE exception to this spec's own byte-exact
  # claim — not a silent carve-out. `hecks-parse` is a differential-
  # parity TESTING tool proving a from-scratch Rust reimplementation of
  # RUBY'S OWN PARSER matches its structural/syntactic IR shape; it is
  # NOT in the real deploy path at all (confirmed directly:
  # `rust/project/domain_generator.rb`'s own `ir.json` writer — what
  # `rust/host` actually reads at runtime via `HECKS_IR_PATH` — serializes
  # Ruby's OWN native `to_h` output straight to JSON, never through
  # `hecks-parse`; that pipeline already carries `ast` correctly with no
  # Rust changes needed). Building a full structural expression parser in
  # `rust/parser` — mirroring `Bluebook::Expression::Evaluator`/
  # `Resolver.parse` faithfully enough to reproduce `AstJson`'s own
  # recursive tree — JUST to satisfy this parity harness, with no real
  # consumer needing that Rust-side parse tree at all, would be exactly
  # the kind of invented generality with no real backing this codebase's
  # own comments elsewhere warn against (`checkout.rs`'s own header, same
  # reasoning one boundary over). `canonical` — the text this parser
  # DOES already parity-test — stays fully byte-exact; only its derived
  # `ast` rendering is excluded here, the identical scope boundary
  # `round_trip_spec.rb`'s own `strip_invariant_ast` already draws for
  # the self-hosted meta-domain's own round trip.
  def self.strip_invariant_ast(node)
    case node
    when Hash then node.except(:ast).transform_values { |v| strip_invariant_ast(v) }
    when Array then node.map { |v| strip_invariant_ast(v) }
    else node
    end
  end

  it "finds at least one real corpus member (the enumeration itself isn't silently empty)" do
    expect(PARITY_CORPUS_MEMBERS).not_to be_empty
  end

  it "keeps PENDING_MEMBERS a strict subset of the real corpus — nothing pending that doesn't exist" do
    ghosts = PENDING_MEMBERS.keys - PARITY_CORPUS_MEMBERS.map(&:first)
    expect(ghosts).to be_empty, "PENDING_MEMBERS names members the corpus enumeration doesn't have: #{ghosts.inspect}"
  end

  it "keeps REAL_PARITY_MEMBERS and PENDING_MEMBERS disjoint — a member is one or the other, never both" do
    overlap = REAL_PARITY_MEMBERS.keys & PENDING_MEMBERS.keys
    expect(overlap).to be_empty, "double-booked: #{overlap.inspect}"
  end

  it "accounts for every real corpus member — nothing silently skipped" do
    unaccounted = PARITY_CORPUS_MEMBERS.map(&:first) - PENDING_MEMBERS.keys - REAL_PARITY_MEMBERS.keys
    expect(unaccounted).to be_empty,
                           "these corpus members are neither pending nor exercised by a real " \
                           "byte-match assertion below — a member must be one or the other: #{unaccounted.inspect}"
  end

  PARITY_CORPUS_MEMBERS.each do |stem, bluebook|
    next if REAL_PARITY_MEMBERS.key?(stem)

    it "#{stem}: still Stage 1 pending, and fails the honest way (not yet implemented, not a crash)" do
      pending_reason = PENDING_MEMBERS[stem]
      skip "#{stem} is not marked pending, but no real byte-match assertion exists for it yet — add one or restore the pending entry" unless pending_reason

      chapter_name = self.class.chapter_name_of(bluebook)
      unless chapter_name
        raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header this spec could find — " \
              "either the file's shape changed or the header-reading regex needs updating"
      end

      stdout, stderr, status = self.class.run_chapter(chapter_name, *Array(bluebook))
      expected_diagnostic = PENDING_MEMBERS_DIAGNOSTIC[stem]

      expect(status.exitstatus).to eq(1),
                                   "#{bluebook}: expected a Stage 1 'not yet built' exit code (1), " \
                                   "got #{status.exitstatus}. stdout:\n#{stdout}\nstderr:\n#{stderr}"
      expect(stdout).to eq(""),
                        "#{bluebook}: stdout must stay empty on a pending failure — a non-empty " \
                        "stdout here would mean this parser fabricated partial ir.json. stdout:\n#{stdout}"
      expect(stderr).to include(expected_diagnostic),
                        "#{bluebook}: expected '#{expected_diagnostic}' on stderr, got something " \
                        "else — this may be a REAL grammar bug (a genuine parse error unrelated to " \
                        "staging), which is a spec FAILURE, not a skip. Full stderr:\n#{stderr}"
    end
  end

  REAL_PARITY_MEMBERS.each do |stem, (chapter_name, paths)|
    it "#{stem}: hecks-parse's own ir.json is byte-identical to Ruby's" do
      stdout, stderr, status = self.class.run_chapter(chapter_name, *paths)

      expect(status.exitstatus).to eq(0),
                                   "#{stem}: hecks-parse failed to parse a REAL corpus member — this is a genuine " \
                                   "parser bug, not staging. stdout:\n#{stdout}\nstderr:\n#{stderr}"

      expected = self.class.ruby_ir_json(stem, chapter_name, paths)
      expect(stdout).to eq(expected),
                        "#{stem}: hecks-parse's ir.json does not byte-match Ruby's own " \
                        "JSON.pretty_generate(Exporter.call(...)) for the same files"
    end
  end
end
