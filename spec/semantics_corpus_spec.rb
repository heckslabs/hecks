require "spec_helper"
require "json"
require "open3"
require "hecks/fuzzing"
require_relative "support/rust_conformance_helpers"

# THE SEMANTICS CORPUS — the executable half of
# docs/semantics/bluebook-semantics.md. Every fixture carries a FROZEN
# `expect` (seeded once by bin/seed_semantics_corpus, reviewed against
# the clauses, then the definition); this spec holds BOTH runtimes to
# the file, never to each other. That is the difference from
# spec/rust_conformance_spec.rb, which proves the runtimes agree — a
# shared bug passes there and fails here the day a clause decides it.
#
# Refusals are compared WITH their kind (the refusal class, C8.2);
# events without `occurred_at` (environmental, C7.3/C9.1).
RSpec.describe "the semantics corpus" do
  SEMANTICS_FIXTURES = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/semantics", "*.json")).freeze
  SEMANTICS_DOC = File.join(InMemoryDomain::ROOT, "docs/semantics/bluebook-semantics.md")

  def load_fixture(path)
    JSON.parse(File.read(path))
  end

  def normalize_events(events)
    JSON.parse(JSON.generate(events)).each { |e| e.delete("occurred_at") }
  end

  it "has fixtures, and every fixture carries a frozen expect" do
    expect(SEMANTICS_FIXTURES).not_to be_empty
    SEMANTICS_FIXTURES.each do |path|
      expect(load_fixture(path)).to have_key("expect"),
                                    "#{File.basename(path)} has no expect — run bin/seed_semantics_corpus, " \
                                    "review the seed against the clauses, and commit it"
    end
  end

  # THE REVERSE OF THE CHECK BELOW — every fixture the document cites
  # must exist. Stage 5 wrote seven citations ahead of their files, and
  # nothing noticed until a reader went looking; a cited fixture that
  # does not exist is a clause pinned by nothing.
  it "has a file for every fixture docs/semantics/bluebook-semantics.md cites" do
    cited = File.read(SEMANTICS_DOC).scan(/fixtures?:\s*((?:`[^`]+\.json`[\s,]*)+)/).flatten
                .flat_map { |group| group.scan(/`([^`]+\.json)`/).flatten }.uniq
    expect(cited).not_to be_empty
    missing = cited.reject { |name| File.exist?(File.join(InMemoryDomain::ROOT, "spec/corpus/semantics", name)) }
    expect(missing).to eq([]), "cited but absent: #{missing.join(', ')}"
  end

  it "cites only clauses docs/semantics/bluebook-semantics.md declares" do
    doc = File.read(SEMANTICS_DOC)
    SEMANTICS_FIXTURES.each do |path|
      load_fixture(path).fetch("spec").each do |clause|
        expect(doc).to include("**#{clause} "),
                       "#{File.basename(path)} cites #{clause}, which the semantics document does not declare"
      end
    end
  end

  # A PARTITION, NOT A FILTER. Every fixture lands in exactly one bucket:
  # held to the Rust kernel below (gating), or `ruby_only` — and a
  # ruby_only fixture is not a silent exclusion: it carries a
  # `ruby_only_reason`, checked here against what it claims (a missing
  # Cargo feature must really be missing), and the non-gating report
  # below still runs it against Rust wherever a binary exists.
  RUBY_ONLY_FEATURELESS = "rust/Cargo.toml".freeze

  def self.cargo_feature?(feature)
    File.read(File.join(InMemoryDomain::ROOT, "rust/Cargo.toml")).match?(/^#{Regexp.escape(feature)}\s*=\s*\[\]/)
  end

  it "gives every ruby_only fixture a reason that holds up, and no other fixture one" do
    problems = SEMANTICS_FIXTURES.filter_map do |path|
      fixture = load_fixture(path)
      name = File.basename(path)
      reason = fixture["ruby_only_reason"]
      feature = File.basename(fixture.fetch("domain")).downcase

      if !fixture["ruby_only"]
        "#{name}: carries a ruby_only_reason but is not ruby_only — delete the reason" if fixture.key?("ruby_only_reason")
      elsif !reason.is_a?(String) || reason.strip.empty?
        "#{name}: ruby_only with no ruby_only_reason — say why Rust isn't held to it (or \"unverified: <what differs>\")"
      elsif !self.class.cargo_feature?(feature) && !reason.include?(RUBY_ONLY_FEATURELESS)
        "#{name}: its domain has no `#{feature}` feature in rust/Cargo.toml, and the reason doesn't say so"
      elsif self.class.cargo_feature?(feature) && reason.include?("no `#{feature}` feature")
        "#{name}: the reason says there is no `#{feature}` feature, but rust/Cargo.toml has one — re-check the fixture"
      end
    end
    expect(problems).to be_empty, problems.join("\n")
  end

  describe "the Ruby runtime answers every fixture as written" do
    SEMANTICS_FIXTURES.each do |fixture_path|
      it File.basename(fixture_path) do
        fixture  = load_fixture(fixture_path)
        expected = fixture.fetch("expect")

        result = Hecks::Fuzzing::Replay.call(File.join(InMemoryDomain::ROOT, fixture.fetch("domain")),
                                             fixture.fetch("steps"))

        refusals = JSON.parse(JSON.generate(result[:refusals])).each { |r| r["kind"] = r["kind"]&.split("::")&.last }
        expect(refusals).to eq(expected.fetch("refusals"))
        expect(JSON.parse(JSON.generate(result[:instances]))).to eq(expected.fetch("instances"))
        expect(normalize_events(result[:events])).to eq(expected.fetch("events"))
      end
    end
  end

  # The same fixtures, answered by the compiled Rust kernel — refusal
  # kinds included, which spec/rust_conformance historically dropped.
  # `io: true`: a cargo build inside rspec, by this suite's convention.
  describe "the Rust kernel answers every fixture as written", :io do
    include RustConformanceHelpers

    def build_rust_for(domain_feature)
      super(domain_feature, File.join(InMemoryDomain::ROOT, "rust"))
    end

    def rust_answer(binary, fixture)
      stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => fixture.fetch("steps") }))
      return [nil, "#{binary} exited #{status.exitstatus}:\n#{stdout}"] unless status.success?

      rust = JSON.parse(stdout)
      strip_emitted_flags!(rust["instances"])
      strip_occurred_at!(rust["events"])
      [rust, nil]
    end

    SEMANTICS_FIXTURES.each do |fixture_path|
      # ruby_only fixtures are the other half of the partition — the
      # report below, not a skip here.
      next if JSON.parse(File.read(fixture_path))["ruby_only"]

      it File.basename(fixture_path) do
        fixture = load_fixture(fixture_path)

        feature = File.basename(fixture.fetch("domain")).downcase
        binary  = build_rust_for(feature)
        skip "rust/Cargo.toml has no #{feature} feature — run bin/project_rust for it first" unless binary

        rust, failure = rust_answer(binary, fixture)
        expect(failure).to be_nil, failure

        expected = fixture.fetch("expect")
        expect(rust.fetch("refusals")).to eq(expected.fetch("refusals"))
        expect(rust.fetch("instances")).to eq(expected.fetch("instances"))
        expect(rust.fetch("events")).to eq(expected.fetch("events"))
      end
    end

    # NON-GATING, BY DESIGN — it reports, it never fails. A ruby_only
    # fixture Rust now answers exactly is a flag waiting to be removed;
    # this is where that shows up. Build failures are reported, not
    # raised: the gating examples above own "the crate builds".
    it "reports which ruby_only fixtures the Rust kernel now answers as written (non-gating)" do
      lines = SEMANTICS_FIXTURES.select { |path| load_fixture(path)["ruby_only"] }.map do |path|
        fixture = load_fixture(path)
        feature = File.basename(fixture.fetch("domain")).downcase
        binary = begin
          build_rust_for(feature)
        rescue StandardError => e
          next "  #{File.basename(path)}: build failed — #{e.message.lines.first&.strip}"
        end
        next "  #{File.basename(path)}: no binary (rust/Cargo.toml has no #{feature} feature)" unless binary

        rust, failure = rust_answer(binary, fixture)
        next "  #{File.basename(path)}: Rust crashed — #{failure.lines.first.strip}" if failure

        expected = fixture.fetch("expect")
        agrees = %w[refusals instances events].all? { |key| rust.fetch(key) == expected.fetch(key) }
        "  #{File.basename(path)}: #{agrees ? 'NOW PASSES against Rust — drop ruby_only' : 'still differs'}"
      end
      RSpec.configuration.reporter.message("ruby_only semantics fixtures against Rust:\n#{lines.join("\n")}")
      expect(lines.size).to eq(SEMANTICS_FIXTURES.count { |path| load_fixture(path)["ruby_only"] })
    end
  end
end
