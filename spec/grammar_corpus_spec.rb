require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# Pins docs/semantics/bluebook-grammar.md's G-clauses: each fixture's expect_ast, re-derived
# from AstJson, must equal hecks-parse's ast. ruby_only fixtures (G11) are checked on Ruby only.
RSpec.describe "the Bluebook expression grammar (docs/semantics/bluebook-grammar.md)" do
  GRAMMAR_FIXTURE_DIR = File.expand_path("corpus/grammar", __dir__)
  GRAMMAR_FIXTURES    = Dir.glob(File.join(GRAMMAR_FIXTURE_DIR, "*.json")).freeze

  AstJson = Hecks::Bluebook::Expression::AstJson

  CITE_G_CLAUSE = "a ruby_only grammar fixture must cite the G-clause that catalogues why hecks-parse isn't held to it".freeze

  def self.fixture_of(path) = JSON.parse(File.read(path))

  def self.ruby_only?(path) = fixture_of(path).fetch("ruby_only", false)

  def fixture_of(path) = self.class.fixture_of(path)

  # One sentence for each fixture whose frozen expect_ast AstJson no longer answers.
  def drift_messages
    GRAMMAR_FIXTURES.filter_map do |path|
      fixture = fixture_of(path)
      live = JSON.parse(JSON.generate(AstJson.emit_predicate(fixture.fetch("canonical"))))
      next if live == fixture.fetch("expect_ast")

      "#{File.basename(path)}: AstJson.emit_predicate(canonical) has drifted from the fixture's own frozen " \
        "expect_ast — re-review and re-freeze, don't just copy the new answer over"
    end
  end

  # The [holds, problem] checks of a ruby_only fixture: its note must cite G11 and name a gap, and its
  # reason must name the same gap id the note catalogues, so it cannot drift.
  def ruby_only_checks(fixture)
    gap_ids = fixture.fetch("note").scan(/KNOWN GAP \((G\d+)/).flatten
    reason = fixture["ruby_only_reason"].to_s
    [[fixture.fetch("note").include?("G11"), CITE_G_CLAUSE],
     [!reason.strip.empty?, "ruby_only with no ruby_only_reason"],
     [!gap_ids.empty?, "its note names no KNOWN GAP (Gnn) id"]] +
      gap_ids.map { |id| [reason.include?("KNOWN GAP #{id}"), "ruby_only_reason must reference the KNOWN GAP id #{id}"] }
  end

  # What is wrong with a ruby_only fixture's note and reason.
  def ruby_only_problems(path)
    ruby_only_checks(fixture_of(path)).reject(&:first).map { |_, problem| "#{File.basename(path)}: #{problem}" }
  end

  # A reason on a fixture that is not ruby_only is a leftover.
  def stray_reasons
    GRAMMAR_FIXTURES.reject { |path| self.class.ruby_only?(path) }.select { |path| fixture_of(path).key?("ruby_only_reason") }
                    .map { |path| "#{File.basename(path)}: a reason on a fixture that isn't ruby_only" }
  end

  it "has fixtures, and every fixture's expect_ast is exactly what AstJson.emit_predicate answers today", :aggregate_failures do
    expect(GRAMMAR_FIXTURES).not_to be_empty
    expect(drift_messages).to be_empty
  end

  it "names every ruby_only fixture as a known, catalogued gap — never a silent one", :aggregate_failures do
    ruby_only = GRAMMAR_FIXTURES.select { |path| self.class.ruby_only?(path) }
    expect(ruby_only).not_to be_empty

    expect(ruby_only.flat_map { |path| ruby_only_problems(path) }).to be_empty
    expect(stray_reasons).to be_empty
  end

  describe "hecks-parse held to it", :io do
    RUST_PARSER_DIR = File.expand_path("../rust/parser", __dir__)
    GRAMMAR_BINARY  = File.join(RUST_PARSER_DIR, "target", "debug", "hecks-parse")

    # cargo's stderr goes into the failure: a CI runner is gone by the time anyone looks.
    def self.build_parser!
      _stdout, stderr, status = Open3.capture3("cargo", "build", chdir: RUST_PARSER_DIR)
      raise "cargo build failed for rust/parser (exit #{status.exitstatus}):\n#{stderr}" unless status.success?
      raise "cargo build did not produce #{GRAMMAR_BINARY}" unless File.executable?(GRAMMAR_BINARY)
    end

    before(:context) { self.class.build_parser! }

    # One scratch bluebook reused per fixture; only the canonical text varies. Declared names let
    # every fixture's receivers resolve, so failures are about the grammar, not undeclared names.
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

    # The host bluebook with the fixture's own name and canonical text filled in.
    def self.host_source(path, fixture)
      HOST_BLUEBOOK.sub("TMPL_DESCRIPTION", File.basename(path, ".json"))
                   .sub("TMPL_CANONICAL", fixture.fetch("canonical"))
    end

    # [ast, nil] on a clean parse, [nil, failure text] otherwise.
    def self.hecks_parse_ast(path, fixture)
      Dir.mktmpdir do |dir|
        bluebook_path = File.join(dir, "grammar_corpus_host.bluebook")
        File.write(bluebook_path, host_source(path, fixture))

        stdout, stderr, status = run_chapter(bluebook_path)
        next [nil, "hecks-parse chapter failed:\n#{stderr}\n#{stdout}"] unless status.success?

        [JSON.parse(stdout).fetch("aggregates").first.fetch("commands").first.fetch("givens").first.fetch("ast"), nil]
      end
    end

    # One line of the non-gating report: what hecks-parse does with a ruby_only fixture.
    def self.verdict_line(path)
      ast, failure = hecks_parse_ast(path, fixture_of(path))
      verdict = if failure then "hecks-parse refused it"
                elsif ast == fixture_of(path).fetch("expect_ast") then "NOW MATCHES Ruby — drop ruby_only"
                else "still differs"
                end
      "  #{File.basename(path)}: #{verdict}"
    end

    def divergence_message(fixture)
      "hecks-parse's own ast for `#{fixture.fetch("canonical")}` diverges from Ruby's — " \
        "see docs/semantics/bluebook-grammar.md for the G-clause this pins"
    end

    GRAMMAR_FIXTURES.each do |path|
      # ruby_only fixtures are covered by the non-gating report below.
      next if ruby_only?(path)

      it "#{File.basename(path, ".json")}: hecks-parse's own ast matches Ruby's", :aggregate_failures do
        fixture = fixture_of(path)
        ast, failure = self.class.hecks_parse_ast(path, fixture)
        expect(failure).to be_nil, failure
        expect(ast).to eq(fixture.fetch("expect_ast")), divergence_message(fixture)
      end
    end

    # Non-gating: a ruby_only fixture that now matches is a closed gap whose flag can be dropped.
    it "reports which ruby_only fixtures hecks-parse now parses to Ruby's tree (non-gating)" do
      lines = GRAMMAR_FIXTURES.select { |path| self.class.ruby_only?(path) }.map { |path| self.class.verdict_line(path) }
      RSpec.configuration.reporter.message("ruby_only grammar fixtures against hecks-parse:\n#{lines.join("\n")}")
      expect(lines.size).to eq(GRAMMAR_FIXTURES.count { |path| self.class.ruby_only?(path) })
    end
  end
end
