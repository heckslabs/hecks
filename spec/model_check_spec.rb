require "spec_helper"
require "hecks/bluebook/model_check"

# The lightweight-formal-methods leg of the verification arc: every
# lifecycle is a declared FSM and every process manager a declared
# protocol, so both can be MODEL-CHECKED — unreachable states, dead
# transitions, saga states no handler chain reaches, a compensation
# whose from_state is unreachable (the deadlock class this arc named),
# dispatches to nowhere, handlers listening for an event nothing emits.
RSpec.describe "the model checker" do
  ROOT_DIR = InMemoryDomain::ROOT

  def boot(bluebook)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(bluebook)

      # THE SIBLING HECKSAGON, IF ONE EXISTS — see bin/model_check's own
      # copy of this comment. Fixtures under spec/fixtures/model_check/
      # have none, so this is a no-op for every test but the real corpus.
      hecksagon = if File.directory?(bluebook)
                    Dir.glob(File.join(bluebook, "*.hecksagon")).sort.first
                  else
                    bluebook.sub(/\.bluebook\z/, ".hecksagon")
                  end
      Kernel.load(hecksagon) if hecksagon && File.exist?(hecksagon)
    end
    registry.bluebooks.values.first
  end

  def findings_for(name)
    path = File.join(ROOT_DIR, "spec/fixtures/model_check/#{name}.bluebook")
    Hecks::Bluebook::ModelCheck.call(boot(path))
  end

  def has?(findings, kind, subject)
    findings.any? { |f| f.kind == kind && f.subject == subject }
  end

  describe "lifecycle findings" do
    let(:findings) { findings_for("lifecycle_findings") }

    it "finds a state nothing ever transitions into" do
      expect(has?(findings, :unreachable_state, "Widget")).to be(true)
    end

    it "finds a transition whose own from: state is never reached" do
      expect(has?(findings, :dead_transition, "Widget")).to be(true)
    end

    it "finds a transition naming a command the aggregate never declares" do
      finding = findings.find { |f| f.kind == :unknown_command && f.subject == "Widget" }
      expect(finding.message).to include('"Vanish"')
    end

    it "warns (not errors) on a reachable state nothing ever leaves — an entity's lifecycle too" do
      finding = findings.find { |f| f.kind == :stuck_state && f.subject == "Widget::Part" }
      expect(finding.severity).to eq(:warning)
    end

    it "raises no finding kind outside the ones this fixture deliberately triggers" do
      # NOT an exact count: "Vanish"'s own from: ("active") is itself
      # reached via Activate, so its target ("gone") cascades into
      # reachable-but-stuck too — a second, legitimate unreachable_state
      # (the untouched "abandoned") and a stuck_state ride along. The
      # fixture's job is proving each KIND fires at least once, not
      # pinning how many states a hand-written FSM happens to produce.
      expect(findings.select { |f| f.subject == "Widget" }.map(&:kind).uniq.sort)
        .to eq(%i[dead_transition stuck_state unknown_command unreachable_state].sort)
    end
  end

  describe "saga findings" do
    let(:findings) { findings_for("saga_findings") }

    it "finds a declared PM state no handler chain reaches" do
      expect(has?(findings, :unreachable_pm_state, "LegSaga")).to be(true)
    end

    it "finds a compensation whose from_state is unreachable — the deadlock class" do
      finding = findings.find { |f| f.kind == :dead_compensation && f.subject == "LegSaga" }
      expect(finding.message).to include('"advanced"')
    end

    it "finds a dispatch to a command that does not exist" do
      finding = findings.find { |f| f.kind == :unknown_dispatch && f.subject == "LegSaga" }
      expect(finding.message).to include("Leg.Launch")
    end

    it "finds a handler listening for an event nothing emits" do
      finding = findings.find { |f| f.kind == :deaf_handler && f.subject == "LegSaga" }
      expect(finding.message).to include('"LegAdvanced"')
    end

    it "finds ends_on naming an event nothing emits" do
      finding = findings.find { |f| f.kind == :deaf_trigger && f.subject == "LegSaga" }
      expect(finding.message).to include('"LegFinished"')
    end

    it "never flags the REFUSED compensation leg as a deaf handler" do
      # The compensating leg answers "refused", a synthetic trigger no
      # command ever emits by name — the one handler this domain's own
      # events can never satisfy on purpose, and not a finding.
      deaf = findings.select { |f| f.kind == :deaf_handler }
      expect(deaf.map(&:message)).not_to include(a_string_matching(/refused/))
    end
  end

  describe "policy findings" do
    let(:findings) { findings_for("policy_findings") }

    it "finds a policy listening for an event nothing emits" do
      expect(has?(findings, :deaf_policy, "OnArchive")).to be(true)
    end

    it "finds a trigger that resolves to no command this domain declares" do
      finding = findings.find { |f| f.kind == :unknown_trigger && f.subject == "OnWrite" }
      expect(finding.message).to include('"Note.Vanish"')
    end

    it "does not flag a trigger that resolves — Note.Stamp genuinely exists" do
      expect(findings.map(&:subject)).not_to include("OnArchive2")
      archive_findings = findings.select { |f| f.subject == "OnArchive" }
      expect(archive_findings.map(&:kind)).to eq([:deaf_policy])
    end
  end

  # THE COVERAGE GATE. `bin/model_check` runs this same walk over every
  # example domain, every grammar chapter, and the language itself — the
  # spec keeps that corpus finding-free by holding it to bin/model_check's
  # own allowlist: an error the tool reports and the allowlist does not
  # name is a regression ; an allowlist entry the tool no longer reports
  # is stale and must be deleted, the same both-directions discipline
  # plurality_coverage_spec's ALLOWED_SINGLETON holds itself to.
  describe "the real corpus" do
    def self.bluebook_in(domain)
      nested = File.join(domain, "bluebook")
      return nested if Dir.glob(File.join(nested, "*.bluebook")).any?

      domain if Dir.glob(File.join(domain, "*.bluebook")).any?
    end

    MODEL_CHECK_EXAMPLE_ROOTS = Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "*"))
                                   .select { |path| File.directory?(path) }.sort.freeze
    MODEL_CHECK_GRAMMAR_CHAPTERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/grammar", "*.bluebook")).sort.freeze
    # `lib/hecks/framework/bluebook/`'s flat sibling-file shape — see corpus_spec.rb's
    # own FRAMEWORK_MEMBERS comment for why this isn't EXAMPLE_ROOTS-shaped.
    MODEL_CHECK_FRAMEWORK_MEMBERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook",
                                                       "*.bluebook")).sort.freeze

    MODEL_CHECK_CORPUS = (
      MODEL_CHECK_EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebook_in(domain)] } +
      MODEL_CHECK_GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] } +
      MODEL_CHECK_FRAMEWORK_MEMBERS.map { |member| [File.basename(member, ".bluebook"), member] }
    ).reject { |_, source| source.nil? }.freeze

    # The SAME constant bin/model_check reads — one table, not a copy.
    MODEL_CHECK_ALLOWED = Hecks::Bluebook::ModelCheck::ALLOWED_FINDINGS

    MODEL_CHECK_CORPUS.each do |name, source|
      it "#{name} has no error bin/model_check does not already name" do
        findings = Hecks::Bluebook::ModelCheck.call(boot(source))
        errors   = findings.select { |f| f.severity == :error }
        allowed  = MODEL_CHECK_ALLOWED.fetch(name, [])

        unnamed = errors.reject { |f| allowed.include?([f.kind, f.subject]) }
        expect(unnamed).to be_empty, unnamed.map(&:to_s).join("\n")
      end
    end

    it "names nothing in the allowlist that the checker no longer finds" do
      MODEL_CHECK_ALLOWED.each do |name, entries|
        source = MODEL_CHECK_CORPUS.to_h.fetch(name) { next }
        findings = Hecks::Bluebook::ModelCheck.call(boot(source))
        found = findings.select { |f| f.severity == :error }.map { |f| [f.kind, f.subject] }

        stale = entries - found
        expect(stale).to be_empty, "#{name}: #{stale.inspect} no longer found — delete from ALLOWED_FINDINGS"
      end
    end

    it "the language itself is clean" do
      %w[Bluebook World].each do |name|
        chapter = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook(name)
        next unless chapter

        errors = Hecks::Bluebook::ModelCheck.call(chapter).select { |f| f.severity == :error }
        expect(errors).to be_empty, errors.map(&:to_s).join("\n")
      end
    end
  end
end
