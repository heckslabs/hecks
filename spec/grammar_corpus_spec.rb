require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# THE EXPRESSION GRAMMAR'S OWN ACCEPT CORPUS — docs/semantics/
# bluebook-grammar.md's G-clauses, pinned. `spec/parser_parity_spec.rb`
# already holds `hecks-parse` to Ruby's own CONSTRUCT/keyword surface
# byte-for-byte, over the real corpus; `spec/syntax_conformance_spec.rb`
# holds the DSL builders to the language's own self-hosted Syntax table.
# Neither ever isolates one EXPRESSION and asks "does this specific
# precedence-sensitive shape parse to the same tree on both engines" —
# that gap is this file's.
#
# Every fixture (`spec/corpus/grammar/*.json`) carries the canonical
# source text and the ROOT node Ruby's own `AstJson.emit_predicate`
# emits for it — the SAME oracle `spec/expression_ast_spec.rb` already
# trusts, re-derived fresh here (never hand-typed), so a fixture can
# never silently drift from what `Evaluator.parse`/`AstJson` themselves
# would answer today. `hecks-parse chapter`'s own emitted `ast`, for one
# rule row of a tiny scratch bluebook wrapping the same canonical text,
# is compared against it directly — agreement on STRUCTURE, not merely
# "didn't crash."
#
# `ruby_only: true` fixtures (docs/semantics/bluebook-grammar.md's G11 —
# `hecks-parse`'s own expression resolver has no production at all for
# seven ops: MatchesRegex, Presence, Split, StartsWith, EndsWith, First,
# Last; each falls through to the `Lookup` catch-all instead) are pinned
# on the RUBY side only — hecks-parse's own (wrong) answer is not
# compared, so this file states the gap once, honestly, rather than
# either hiding it or leaving the whole corpus failing.
#
# TWO NESTED groups, deliberately: the fixtures' own freshness (Ruby-
# only, no cargo needed) runs in the ordinary non-io suite, on every
# commit; `hecks-parse held to it` needs a real build, `io: true`, the
# same convention `parser_parity_spec` already uses — excluded locally
# by default, always run in CI.
RSpec.describe "the Bluebook expression grammar (docs/semantics/bluebook-grammar.md)" do
  GRAMMAR_FIXTURE_DIR = File.expand_path("corpus/grammar", __dir__)
  GRAMMAR_FIXTURES    = Dir.glob(File.join(GRAMMAR_FIXTURE_DIR, "*.json")).freeze

  AstJson = Hecks::Bluebook::Expression::AstJson

  it "has fixtures, and every fixture's expect_ast is exactly what AstJson.emit_predicate answers today" do
    expect(GRAMMAR_FIXTURES).not_to be_empty

    GRAMMAR_FIXTURES.each do |path|
      fixture = JSON.parse(File.read(path))
      live = JSON.parse(JSON.generate(AstJson.emit_predicate(fixture.fetch("canonical"))))
      expect(live).to eq(fixture.fetch("expect_ast")), "#{File.basename(path)}: AstJson.emit_predicate(canonical) " \
                                                       "has drifted from the fixture's own frozen expect_ast — " \
                                                       "re-review and re-freeze, don't just copy the new answer over"
    end
  end

  it "names every ruby_only fixture as a known, catalogued gap — never a silent one" do
    ruby_only = GRAMMAR_FIXTURES.select { |path| JSON.parse(File.read(path)).fetch("ruby_only", false) }
    expect(ruby_only).not_to be_empty

    ruby_only.each do |path|
      fixture = JSON.parse(File.read(path))
      expect(fixture.fetch("note")).to include("G11"), "#{File.basename(path)}: a ruby_only grammar fixture must " \
                                                       "cite the G-clause that catalogues why hecks-parse isn't " \
                                                       "held to it"
    end
  end

  describe "hecks-parse held to it", :io do
    RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
    GRAMMAR_BINARY  = File.join(RUST_PARSER_DIR, "target", "debug", "hecks-parse")

    def self.build_parser!
      built = system("cargo", "build", chdir: RUST_PARSER_DIR, out: File::NULL, err: File::NULL)
      raise "cargo build failed for rust/parser — run `cargo build` there directly to see why" unless built
      raise "cargo build did not produce #{GRAMMAR_BINARY}" unless File.executable?(GRAMMAR_BINARY)
    end

    before(:context) { self.class.build_parser! }

    # ONE SCRATCH BLUEBOOK, one command, one `given` — reused across
    # every fixture by substituting only the canonical text, the same
    # "vary the one thing under test" shape `spec/deploy_bluebook_spec
    # .rb`'s own scratch-fixture helper uses. `hecks-parse chapter`
    # parses a whole FILE, not a bare expression, so this is the
    # minimal host every fixture needs regardless of which of the 28
    # ops it exercises — `tags`/`forbidden`/`toppings`/etc. are declared
    # broadly enough that every fixture's own receivers resolve to a
    # real head, never an undeclared-name refusal unrelated to the
    # grammar point being pinned.
    HOST_BLUEBOOK = <<~RUBY
      Hecks.bluebook "GrammarCorpusHost" do
        aggregate "Thing" do
          identified_by :name
          attribute :name, ThingName
          attribute :status, String
          attribute :customer_status, String
          attribute :flagged, String
          attribute :sequence, Integer
          attribute :rate, Float
          attribute :middle_name, String
          attribute :full_name, String
          attribute :reference, String
          attribute :filename, String
          attribute :tags, list_of(TagName)
          attribute :toppings, list_of(Topping)
          attribute :seats, list_of(Seat)
          attribute :crew, list_of(CrewMember)

          value_object "ThingName" do
            attribute :value, String
          end

          value_object "TagName" do
            attribute :value, String
          end

          value_object "Topping" do
            attribute :amount, TagName
          end

          value_object "Seat" do
            attribute :number, TagName
            attribute :row, TagName
          end

          value_object "CrewMember" do
            attribute :id, TagName
          end

          command "Exercise" do
            attribute :name, ThingName
            attribute :amount, Integer
            attribute :forbidden, TagName
            attribute :member, TagName
            attribute :number, TagName

            given("TMPL_DESCRIPTION") { TMPL_CANONICAL }

            sets :name
            emits "ThingExercised"
          end
        end
      end
    RUBY
                    .freeze

    def self.run_chapter(*paths)
      Open3.capture3(GRAMMAR_BINARY, "chapter", "--chapter", "GrammarCorpusHost", *paths)
    end

    GRAMMAR_FIXTURES.each do |path|
      next if JSON.parse(File.read(path)).fetch("ruby_only", false)

      it "#{File.basename(path, '.json')}: hecks-parse's own ast matches Ruby's" do
        fixture = JSON.parse(File.read(path))
        source = HOST_BLUEBOOK.sub("TMPL_DESCRIPTION", File.basename(path, ".json"))
                              .sub("TMPL_CANONICAL", fixture.fetch("canonical"))

        Dir.mktmpdir do |dir|
          bluebook_path = File.join(dir, "grammar_corpus_host.bluebook")
          File.write(bluebook_path, source)

          stdout, stderr, status = self.class.run_chapter(bluebook_path)
          expect(status.success?).to be(true), "hecks-parse chapter failed:\n#{stderr}\n#{stdout}"

          ir = JSON.parse(stdout)
          given = ir.fetch("aggregates").first.fetch("commands").first.fetch("givens").first
          expect(given.fetch("ast")).to eq(fixture.fetch("expect_ast")),
                                        "hecks-parse's own ast for `#{fixture.fetch('canonical')}` diverges " \
                                        "from Ruby's — see docs/semantics/bluebook-grammar.md for the G-clause " \
                                        "this pins"
        end
      end
    end
  end
end
