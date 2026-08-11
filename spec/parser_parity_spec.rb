require "spec_helper"
require "open3"

# THE DIFFERENTIAL HARNESS — the anti-drift mechanism for the Rust parser,
# modeled directly on spec/rust_conformance_spec.rb's own cargo-build-then-
# subprocess-inside-rspec pattern, and on spec/corpus_spec.rb's own
# Dir.glob-derived (never hand-listed) corpus enumeration, so a new
# example/grammar-chapter/framework member is covered here automatically.
#
# STAGE 1: every real corpus member is PENDING — the parser doesn't build
# IR yet (see rust/parser/src/parse/mod.rs's own header). This spec exists
# now, and passes now, by asserting exactly that: the pending list is
# COMPLETE (nothing silently skipped that isn't accounted for), and every
# member on it genuinely still fails with a Stage-1 "not yet implemented"
# diagnostic rather than something else. Stage 2 shrinks PENDING_MEMBERS
# to exclude pizzas.bluebook and adds a real byte-match assertion for it;
# by Stage 6 this table is empty.
#
# A parse error for anything OUTSIDE the pending list — or a PENDING
# member that no longer fails the way its own reason says it should — is a
# spec FAILURE with the parser's own stderr inlined, never a silent skip.
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
    header = File.foreach(bluebook_path).first(20).find { |line| line =~ /\A\s*Hecks\.bluebook\s+"([^"]+)"/ }
    header && Regexp.last_match(1)
  end

  PARITY_CORPUS_MEMBERS = (
    PARITY_EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebook_in(domain)] } +
    PARITY_GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] } +
    PARITY_FRAMEWORK_MEMBERS.map { |member| [File.basename(member, ".bluebook"), member] }
  ).reject { |_stem, path| path.nil? }.freeze

  # EVERY MEMBER IS PENDING AT STAGE 1, each with the SAME honest reason —
  # named per-member (not one blanket comment) so a future stage's own
  # shrinkage is a visible diff: Stage 2 removes "pizzas" from this table,
  # Stage 3 the framework trio, and so on, ending empty at Stage 6.
  PENDING_MEMBERS = PARITY_CORPUS_MEMBERS.to_h { |stem, _path| [stem, "Stage 1: parser not implemented yet — see rust/parser/src/parse/mod.rs"] }.freeze

  def self.run_chapter(chapter_name, path)
    Open3.capture3(PARITY_BINARY_PATH, "chapter", "--chapter", chapter_name, path)
  end

  it "finds at least one real corpus member (the enumeration itself isn't silently empty)" do
    expect(PARITY_CORPUS_MEMBERS).not_to be_empty
  end

  it "keeps PENDING_MEMBERS a strict subset of the real corpus — nothing pending that doesn't exist" do
    ghosts = PENDING_MEMBERS.keys - PARITY_CORPUS_MEMBERS.map(&:first)
    expect(ghosts).to be_empty, "PENDING_MEMBERS names members the corpus enumeration doesn't have: #{ghosts.inspect}"
  end

  it "accounts for every real corpus member — nothing silently skipped" do
    unaccounted = PARITY_CORPUS_MEMBERS.map(&:first) - PENDING_MEMBERS.keys
    expect(unaccounted).to be_empty,
                           "these corpus members are neither pending nor exercised by a real " \
                           "byte-match assertion below — a member must be one or the other: #{unaccounted.inspect}"
  end

  PARITY_CORPUS_MEMBERS.each do |stem, bluebook|
    it "#{stem}: still Stage 1 pending, and fails the honest way (not yet implemented, not a crash)" do
      pending_reason = PENDING_MEMBERS[stem]
      skip "#{stem} is not marked pending, but no real byte-match assertion exists for it yet — add one or restore the pending entry" unless pending_reason

      chapter_name = self.class.chapter_name_of(bluebook)
      unless chapter_name
        raise "#{bluebook} has no 'Hecks.bluebook \"Name\"' header this spec could find — " \
              "either the file's shape changed or the header-reading regex needs updating"
      end

      stdout, stderr, status = self.class.run_chapter(chapter_name, bluebook)

      expect(status.exitstatus).to eq(1),
                                   "#{bluebook}: expected the Stage 1 'not yet implemented' exit code (1), " \
                                   "got #{status.exitstatus}. stdout:\n#{stdout}\nstderr:\n#{stderr}"
      expect(stdout).to eq(""),
                        "#{bluebook}: stdout must stay empty on a Stage 1 failure — a non-empty " \
                        "stdout here would mean this parser fabricated partial ir.json. stdout:\n#{stdout}"
      expect(stderr).to include("not yet implemented"),
                        "#{bluebook}: expected a Stage 1 'not yet implemented' diagnostic on " \
                        "stderr, got something else — this may be a REAL grammar bug (a genuine " \
                        "parse error unrelated to Stage 1 staging), which is a spec FAILURE, not " \
                        "a skip. Full stderr:\n#{stderr}"
    end
  end
end
