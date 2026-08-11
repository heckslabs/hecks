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
RSpec.describe "Rust parser parity (hecks-parse)" do
  PARITY_RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
  PARITY_BINARY_PATH     = File.join(PARITY_RUST_PARSER_DIR, "target", "debug", "hecks-parse")

  def self.build_parser!
    built = system("cargo", "build", chdir: PARITY_RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{PARITY_BINARY_PATH}" unless File.executable?(PARITY_BINARY_PATH)
  end

  build_parser!

  # THE SAME bluebook-lookup AND Dir.glob ENUMERATION spec/corpus_spec.rb
  # already uses — reused rather than re-derived, so this can never
  # silently drift from what "the corpus" means elsewhere in this suite.
  def self.bluebook_in(domain)
    Dir.glob(File.join(domain, "bluebook", "*.bluebook")).sort.first ||
      Dir.glob(File.join(domain, "*.bluebook")).sort.first
  end

  # The SAME domain's own `.hecksagon`, if it has one — `bin/project_rust`
  # loads it right after the `.bluebook`, and `hecks-parse chapter` needs
  # it fed the same way for a REAL_PARITY_MEMBERS comparison.
  def self.hecksagon_in(domain)
    Dir.glob(File.join(domain, "bluebook", "*.hecksagon")).sort.first ||
      Dir.glob(File.join(domain, "*.hecksagon")).sort.first
  end

  PARITY_EXAMPLE_ROOTS = Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "*")).select { |path| File.directory?(path) }.sort.freeze
  PARITY_GRAMMAR_CHAPTERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecksagain/grammar", "*.bluebook")).sort.freeze
  PARITY_FRAMEWORK_MEMBERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecksagain/framework/bluebook", "*.bluebook")).sort.freeze

  # [chapter name, bluebook path] — the chapter name is what `hecks-parse
  # chapter --chapter <Name>` expects; every real corpus `.bluebook` file
  # declares `Hecks.bluebook "<Name>"` on its own first line, so it's read
  # directly off the file rather than guessed from the filename (a grammar
  # chapter's own file is named after its ROLE — aggregate.bluebook — not
  # its chapter name, which is always "Bluebook").
  def self.chapter_name_of(bluebook_path)
    # No line cap — `File.foreach` is lazy and `.find` stops at the
    # first match regardless, so scanning the whole file costs nothing
    # extra for the common case (every existing corpus member's header
    # sits on line 1 or 2) and doesn't silently miss an outlier: framework/
    # bluebook/interview.bluebook's own header comment runs 33 lines
    # before the declaration, past a 20-line cap this used to carry.
    header = File.foreach(bluebook_path).find { |line| line =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
    header && Regexp.last_match(1)
  end

  PARITY_CORPUS_MEMBERS = (
    PARITY_EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebook_in(domain)] } +
    PARITY_GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] } +
    PARITY_FRAMEWORK_MEMBERS.map { |member| [File.basename(member, ".bluebook"), member] }
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
  # "expression"/"translation" (Stage 3) and, now, "compliance"/
  # "interview" (Stage 4) ALSO come out here, genuine bonuses neither
  # stage set out to build: two concurrently-landed real corpus members
  # (`examples/compliance/`, `lib/hecksagain/framework/bluebook/
  # interview.bluebook`) that Stage 4's own real construction work
  # (entity/process_manager/read-model-options/provenance/nested-policy)
  # happened to fully cover, confirmed byte-exact against Ruby's own
  # `ir.json` before being moved here — the identical discipline every
  # other REAL_PARITY_MEMBERS entry gets. Leaving a member that
  # demonstrably round-trips marked "pending: not yet implemented" would
  # be exactly the kind of false claim this whole harness exists to make
  # impossible, so they're promoted rather than left stale — this is also
  # exactly the safety net working as designed: both showed up as
  # spec FAILURES ("a PENDING member that no longer fails the way its own
  # reason says it should") the moment this stage's real construction
  # work made them stop failing, not a silent pass.
  PENDING_MEMBERS = (PARITY_CORPUS_MEMBERS.map(&:first) -
                     %w[pizzas identity governance console_settings expression translation banking compliance interview])
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
  REAL_PARITY_MEMBERS = %w[pizzas banking compliance].to_h { |stem|
    domain = PARITY_EXAMPLE_ROOTS.find { |path| File.basename(path) == stem } or raise "no examples/#{stem} directory"
    bluebook = bluebook_in(domain) or raise "#{domain} has no .bluebook"
    chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
    [stem, [chapter_name, [bluebook, hecksagon_in(domain)].compact]]
  }.merge(
    # THE FRAMEWORK TRIO (Stage 3) PLUS "interview" (Stage 4's own
    # bonus — see PENDING_MEMBERS' comment). A framework bluebook has no
    # `.hecksagon` of its own (confirmed by reading
    # lib/hecksagain/framework/bluebook/ directly): the comparison target
    # is `hecks-parse chapter --chapter <Name> <bluebook>` standing
    # alone, no `uses_framework`/`resolve` multi-file step needed (that
    # mechanism only matters for a CONSUMING app's own `.hecksagon`,
    # e.g. banking.hecksagon's real `uses_framework "Governance"`/
    # `"Identity"` — real Stage 4 territory, and banking.hecksagon's own
    # sibling `Hecks.hecksagon "Governance"`/`"Identity"` blocks, a SEPARATE
    # finding `parse::chapter`'s own header explains).
    %w[identity governance console_settings interview].to_h { |stem|
      bluebook = PARITY_FRAMEWORK_MEMBERS.find { |path| File.basename(path, ".bluebook") == stem } or
        raise "no lib/hecksagain/framework/bluebook/#{stem}.bluebook"
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
        raise "no lib/hecksagain/grammar/#{stem}.bluebook"
      chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
      [stem, [chapter_name, [bluebook]]]
    }
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
  def self.ruby_ir_json(chapter_name, paths)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      paths.each { |path| Kernel.load(path) }
    end
    ir = Hecksagain::Projector::Exporter.call(registry).fetch(chapter_name)
    "#{JSON.pretty_generate(ir)}\n"
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

      stdout, stderr, status = self.class.run_chapter(chapter_name, bluebook)
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

      expected = self.class.ruby_ir_json(chapter_name, paths)
      expect(stdout).to eq(expected),
                        "#{stem}: hecks-parse's ir.json does not byte-match Ruby's own " \
                        "JSON.pretty_generate(Exporter.call(...)) for the same files"
    end
  end
end
