require "spec_helper"
require "json"
require "open3"

# Differential harness: feeds each corpus member to `hecks-parse` and byte-compares its
# ir.json with the Ruby exporter's output.
RSpec.describe "Rust parser parity (hecks-parse)", :io do
  PARITY_RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
  PARITY_BINARY_PATH     = File.join(PARITY_RUST_PARSER_DIR, "target", "debug", "hecks-parse")

  def self.build_parser!
    built = system("cargo", "build", chdir: PARITY_RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{PARITY_BINARY_PATH}" unless File.executable?(PARITY_BINARY_PATH)
  end

  # A group body still runs when `io: true` excludes its examples, so the build lives in a hook.
  before(:context) { self.class.build_parser! }

  def self.bluebooks_in(domain)
    Hecks::Corpus.bluebook_files(domain) || []
  end

  # Loaded right after the `.bluebook`, as hecks project_rust does.
  def self.hecksagon_in(domain)
    Dir.glob(File.join(domain, "bluebook", "*.hecksagon")).min ||
      Dir.glob(File.join(domain, "*.hecksagon")).min
  end

  PARITY_EXAMPLE_ROOTS = Hecks::Corpus.members(:example).map(&:path).freeze
  PARITY_GRAMMAR_CHAPTERS = Hecks::Corpus.members(:grammar).map(&:path).freeze
  PARITY_FRAMEWORK_MEMBERS = Hecks::Corpus.members(:framework).map(&:path).freeze
  # Globbed recursively so subdirectories such as `eras/` and `model_check/` are covered.
  PARITY_FIXTURES_ROOT = File.join(InMemoryDomain::ROOT, "spec/fixtures")
  PARITY_FIXTURE_MEMBERS = Hecks::Corpus.members(:fixture).map(&:path).freeze

  # The self-hosted grammar: several concept files that together declare one `Bluebook` chapter.
  PARITY_LANGUAGE_GRAMMAR_FILES = Hecks::Bluebook::MetaValidator::GRAMMAR_FILES

  # [chapter name, bluebook path]; the name is read off the file's `Hecks.bluebook` header,
  # since grammar files are named by role, not by chapter.
  def self.chapter_name_of(bluebook_path)
    Hecks::Corpus.chapter_name_of(bluebook_path)
  end

  # Keeps the subdirectory so `eras/base` and a future `model_check/base` cannot collide.
  def self.fixture_stem(path)
    path.delete_prefix("#{PARITY_FIXTURES_ROOT}/").delete_suffix(".bluebook")
  end

  # Suffixes a framework stem that matches an example root (`compliance`). Array#- removes every
  # occurrence of a duplicate stem, so a collision would leave one file unchecked.
  def self.framework_stem(member)
    stem = File.basename(member, ".bluebook")
    PARITY_EXAMPLE_ROOTS.any? { |path| File.basename(path) == stem } ? "#{stem}_framework" : stem
  end

  PARITY_CORPUS_MEMBERS = (
    PARITY_EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebooks_in(domain)] } +
    PARITY_GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] } +
    PARITY_FRAMEWORK_MEMBERS.map { |member| [framework_stem(member), member] } +
    PARITY_FIXTURE_MEMBERS.map { |member| [fixture_stem(member), member] } +
    # One member built from several concept files; not stemmed "bluebook", which is one of them.
    [["bluebook_language", PARITY_LANGUAGE_GRAMMAR_FILES]]
  ).compact.freeze

  # Members not yet byte-matched; promote one to REAL_PARITY_MEMBERS once it round-trips.
  PENDING_MEMBERS = (PARITY_CORPUS_MEMBERS.map(&:first) -
                     %w[pizzas identity governance console_settings expression translation banking compliance
                        compliance_framework roster chess directory bluebook_language embryonaut_vendoring_demo
                        privacy] -
                     PARITY_FIXTURE_MEMBERS.map { |member| fixture_stem(member) })
                    .to_h { |stem| [stem, "Stage 1: parser not implemented yet — see rust/parser/src/parse/mod.rs"] }.freeze

  # Expected stderr for a pending member.
  PENDING_MEMBERS_DIAGNOSTIC = Hash.new("not yet implemented").freeze

  # stem -> [chapter name, files...] in the order hecks project_rust loads them: the `.bluebook`,
  # then its `.hecksagon`. Derived from the corpus, not hand-listed.
  REAL_PARITY_MEMBERS = %w[pizzas banking compliance roster chess directory embryonaut_vendoring_demo].to_h do |stem|
    domain = PARITY_EXAMPLE_ROOTS.find { |path| File.basename(path) == stem } or raise "no examples/#{stem} directory"
    bluebooks = bluebooks_in(domain)
    raise "#{domain} has no .bluebook" if bluebooks.empty?

    chapter_name = chapter_name_of(bluebooks) or raise "#{bluebooks.first} has no 'Hecks.bluebook \"Name\"' header"
    [stem, [chapter_name, bluebooks + [hecksagon_in(domain)].compact]]
  end.merge(
    # Framework chapters stand alone: no `.hecksagon`, so no `attaches` resolution is
    # involved. `compliance` is keyed through `framework_stem` because `examples/compliance`
    # has the same bare stem.
    %w[identity governance console_settings compliance privacy].to_h do |stem|
      bluebook = PARITY_FRAMEWORK_MEMBERS.find { |path| File.basename(path, ".bluebook") == stem } or
        raise "no lib/hecks/framework/bluebook/#{stem}.bluebook"
      chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
      [framework_stem(bluebook), [chapter_name, [bluebook]]]
    end
  ).merge(
    # Grammar chapters stand alone, like the framework chapters.
    %w[expression translation].to_h do |stem|
      bluebook = PARITY_GRAMMAR_CHAPTERS.find { |path| File.basename(path, ".bluebook") == stem } or
        raise "no lib/hecks/grammar/#{stem}.bluebook"
      chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
      [stem, [chapter_name, [bluebook]]]
    end
  ).merge(
    # Every `spec/fixtures/**/*.bluebook`, globbed. `payments.hecksagon` exists for
    # hecks model_check, not for the chapter compared here.
    PARITY_FIXTURE_MEMBERS.to_h do |bluebook|
      stem = fixture_stem(bluebook)
      chapter_name = chapter_name_of(bluebook) or raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header"
      [stem, [chapter_name, [bluebook]]]
    end
  ).merge(
    # The self-hosted grammar: all concept files go to one `hecks-parse chapter` call, in
    # `MetaValidator.load_grammar_into` order. See `ruby_ir_json` for its oracle.
    { "bluebook_language" => [chapter_name_of(PARITY_LANGUAGE_GRAMMAR_FILES.first), PARITY_LANGUAGE_GRAMMAR_FILES] }
  ).freeze

  def self.run_chapter(chapter_name, *paths)
    Open3.capture3(PARITY_BINARY_PATH, "chapter", "--chapter", chapter_name, *paths)
  end

  # Ruby oracle: loads a domain as hecks project_rust does and exports it with `Exporter.call`.
  # Uses Hash insertion order, not the key-sorted golden fixtures.
  def self.ruby_ir_json(stem, chapter_name, paths)
    # `bluebook_language` must go through `grammar_registry`: loading `aggregate.bluebook` the
    # ordinary way fails validation, since it references types declared in later files.
    registry =
      if stem == "bluebook_language"
        Hecks::Bluebook::MetaValidator.grammar_registry
      else
        bluebooks, companions = paths.partition { |path| File.extname(path) == ".bluebook" }
        # `root:` is needed for members declaring `attaches ... from: :vendor`; a bluebook's
        # grandparent is the domain root.
        fresh = Hecks::Runtime::Registry.new(root: File.dirname(bluebooks.first, 2))
        Hecks.with_registry(fresh) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          InMemoryDomain.load_bluebook_files(bluebooks)
          companions.each { |path| Kernel.load(path) }
        end
        fresh
      end
    ir = Hecks::Projector::Exporter.call(registry).fetch(chapter_name)
    "#{JSON.pretty_generate(strip_invariant_ast(ir))}\n"
  end

  # Identity seam: rule `ast` and `where_ast` are emitted by `hecks-parse` and compared as-is.
  def self.strip_invariant_ast(node) = node

  it "finds at least one real corpus member (the enumeration itself isn't silently empty)" do
    expect(PARITY_CORPUS_MEMBERS).not_to be_empty
  end

  # Array#- removes every occurrence of a duplicate stem, so a collision would let the
  # accounting checks below pass while one member goes unchecked.
  it "keeps every corpus member's own stem unique — a collision defeats the accounting checks below" do
    duplicates = PARITY_CORPUS_MEMBERS.map(&:first).tally.select { |_, count| count > 1 }
    expect(duplicates).to be_empty,
                          "these stems name more than one corpus member, which Array#- silently " \
                          "double-cancels in every check below: #{duplicates.keys.inspect}"
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
      unless pending_reason
        skip "#{stem} is not marked pending, but no real byte-match assertion exists for it yet — " \
             "add one or restore the pending entry"
      end

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
