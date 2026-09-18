require "spec_helper"
require "hecks/bluebook/model_check"
require "hecks/fuzzing/target_capabilities"
require "tmpdir"

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
                    Dir.glob(File.join(bluebook, "*.hecksagon")).min
                  else
                    bluebook.sub(/\.bluebook\z/, ".hecksagon")
                  end
      Kernel.load(hecksagon) if hecksagon && File.exist?(hecksagon)
    end
    registry
  end

  # `boot` now returns the REGISTRY, not the bluebook directly — every
  # caller needs `registry.hecksagon(bluebook.name)` too, to exercise the
  # cross-domain relationship findings.
  def call_model_check(registry, known_domains: nil)
    bluebook = registry.bluebooks.values.first
    Hecks::Bluebook::ModelCheck.call(bluebook, hecksagon: registry.hecksagon(bluebook.name), known_domains: known_domains)
  end

  def findings_for(name)
    path = File.join(ROOT_DIR, "spec/fixtures/model_check/#{name}.bluebook")
    call_model_check(boot(path))
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

    it "does not warn on a default state with no outgoing transition, when the lifecycle declares real transitions elsewhere" do
      expect(has?(findings, :stuck_state, "Gadget")).to be(false)
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

    it "finds a compensates declared where the saga has no handler answering a refusal" do
      finding = findings.find { |f| f.kind == :unarmed_compensation && f.subject == "UnarmedSaga" }
      expect(finding.message).to include("Leg.Request compensates Leg.Request")
    end

    it "does not flag a compensates on a saga that DOES answer a refusal — LegSaga has none to flag" do
      expect(findings.select { |f| f.subject == "LegSaga" }.map(&:kind)).not_to include(:unarmed_compensation)
    end

    it "raises no finding kind outside the ones this fixture deliberately triggers" do
      expect(findings.map(&:kind).uniq.sort)
        .to eq(%i[dead_compensation deaf_handler deaf_trigger unarmed_compensation unknown_dispatch
                  unreachable_pm_state].sort)
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

    it "raises no finding kind outside the ones this fixture deliberately triggers" do
      expect(findings.map(&:kind).uniq.sort).to eq(%i[deaf_policy unknown_trigger])
    end

    # BUG#23 — a policy triggering an `asks`/`tells` PORT OPERATION
    # (`Aggregate::Port::Operation`, three colon-joined segments) rather
    # than a plain command (`Aggregate::Command`, two). The real-world
    # case, not a synthetic one: `qa/bluebook/quality_control.bluebook`'s
    # own `FileWhenSubmitted`/`AskOnceMore` policies, both `trigger
    # Ticket::IssueTracker::File`. Before the fix this always reported
    # `unknown_trigger` — `verbs_of` never enumerated a port operation as
    # a triggerable verb, and the comparison read raw strings instead of
    # `Naming.split_verb` triples — even though the same trigger genuinely
    # dispatches at runtime (`PolicyInterpreter#deliver` re-qualifies with
    # this domain's own name, and `Naming.split_verb` already folds the
    # leftover `::` correctly, PR #520). See `Hecks::Bluebook::ModelCheck::
    # ALLOWED_FINDINGS`'s own now-removed "quality_control" entry for the
    # full trace.
    it "does not flag a policy triggering a real, declared port operation (BUG#23)" do
      quality_control = File.join(ROOT_DIR, "qa/bluebook/quality_control.bluebook")
      real_findings = call_model_check(boot(quality_control))

      unknown_triggers = real_findings.select { |f| f.kind == :unknown_trigger }
      expect(unknown_triggers.map(&:subject)).not_to include("FileWhenSubmitted", "AskOnceMore")
    end
  end

  describe "relationship findings (Context Mapping)" do
    let(:findings) { findings_for("relationship_findings") }

    it "finds an across: with nothing in the sibling hecksagon acknowledging it" do
      finding = findings.find { |f| f.kind == :unacknowledged_relationship && f.subject == "OnElsewhere" }
      expect(finding.message).to include('across "Elsewhere"')
    end

    it "finds a domain both uses_framework'd (Shared Kernel) AND reached via across (Customer/Supplier)" do
      finding = findings.find { |f| f.kind == :contradictory_relationship && f.subject == "OnGovernance" }
      expect(finding.message).to include('across "Governance"').and include('uses_framework "Governance"')
    end

    it "does not flag a well-formed across: matched by a subscribe — OnKnown is clean" do
      expect(findings.map(&:subject)).not_to include("OnKnown")
    end

    it "raises no finding kind outside the ones this fixture deliberately triggers" do
      expect(findings.map(&:kind).uniq.sort).to eq(%i[contradictory_relationship unacknowledged_relationship].sort)
    end

    it "checked, not routed — no sibling hecksagon at all means no cross-domain finding either way" do
      # `findings_for` loads the fixture's OWN sibling `.hecksagon`
      # (`boot`'s own comment) — this proves the inverse directly: a
      # bluebook with a cross-domain policy but genuinely NO sibling
      # hecksagon (every other model_check fixture's own shape) raises
      # neither new finding, the same `return [] unless hecksagon` guard
      # `policy_findings.bluebook`'s own OnArchive/OnWrite already prove
      # for the pre-existing same-domain checks.
      no_hecksagon_findings = call_model_check(boot(File.join(ROOT_DIR, "spec/fixtures/model_check/policy_findings.bluebook")))
      expect(no_hecksagon_findings.map(&:kind)).not_to include(:contradictory_relationship, :unacknowledged_relationship)
    end
  end

  # A domain or aggregate whose Rust MODULE name (downcased) is a Rust
  # keyword, or a domain whose module/Cargo feature key is a reserved
  # Cargo.toml key (BUG#124). Warning by default; error with a Rust target
  # or under strict. The Rust generator refuses through the same check.
  describe "Rust reserved names" do
    def reserved_name_findings(domain, aggregate, **options)
      Dir.mktmpdir("model-check-reserved-name") do |dir|
        path = File.join(dir, "#{domain.downcase}.bluebook")
        File.write(path, <<~BLUEBOOK)
          Hecks.bluebook #{domain.inspect} do
            aggregate #{aggregate.inspect} do
              identified_by :code
              attribute :code, #{aggregate}Code
              value_object "#{aggregate}Code" do
                attribute :value, String
              end
              command "Open" do
                attribute :code, #{aggregate}Code
                sets :code
                emits "#{aggregate}Opened"
              end
            end
          end
        BLUEBOOK
        bluebook = boot(path).bluebooks.values.first
        Hecks::Bluebook::ModelCheck.call(bluebook, **options)
                                   .select { |f| f.kind == :rust_reserved_name }
                                   .map { |f| [f.subject, f.severity] }
      end
    end

    [
      ["keyword aggregate, Ruby only",          "Shop",    "Match",   {}, [["Match", :warning]]],
      ["keyword aggregate, Rust target",        "Shop",    "Type",    { rust_target: true }, [["Type", :error]]],
      ["keyword aggregate, strict",             "Shop",    "Crate",   { strict: true }, [["Crate", :error]]],
      ["Cargo-key aggregate is fine",           "Shop",    "Version", { rust_target: true }, []],
      ["Cargo-reserved domain, Ruby only",      "Package", "Widget",  {}, [["Package", :warning]]],
      ["Cargo-reserved domain, Rust target",    "Default", "Widget",  { rust_target: true }, [["Default", :error]]],
      ["keyword domain, strict",                "Crate",   "Widget",  { strict: true },    [["Crate", :error]]],
      ["ordinary names, Rust target and strict", "Shop",   "Pizza",   { rust_target: true, strict: true }, []]
    ].each do |label, domain, aggregate, options, expected|
      it "#{label}: #{domain}/#{aggregate} #{options} -> #{expected}" do
        expect(reserved_name_findings(domain, aggregate, **options)).to eq(expected)
      end
    end

    describe "the Rust generator refuses through the same check" do
      before(:context) { require_relative "../rust/project" }

      def generate(mod_name, *aggregate_names)
        Dir.mktmpdir("model-check-reserved-generator") do |dir|
          out = File.join(dir, mod_name)
          ir = { name: "Shop", aggregates: aggregate_names.map { |name| { name: name } } }
          RustProjection::DomainGenerator.call(ir, "spec", out, mod_name)
        ensure
          expect(Dir.exist?(File.join(dir, mod_name))).to be(false), "refused, but still wrote #{mod_name}/"
        end
      end

      it "refuses every keyword-named aggregate at once, before writing anything" do
        expect { generate("shop", "Pizza", "Match", "Type") }
          .to raise_error(/aggregate name\(s\) "Match", "Type" can't be used as-is .* Rust keyword/)
      end

      it "refuses a domain module name that is a reserved Cargo.toml key" do
        expect { generate("package", "Widget") }.to raise_error(/domain module name "package" can't be used as-is/)
      end
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
    # THE SAME KINDS bin/model_check walks, from the one table both read
    # (Hecks::Corpus). Globbed separately, the ledger (`:qa`) once went
    # missing here while MODEL_CHECK_ALLOWED named it, and
    # `.fetch(name) { next }` below silently returned nil instead of
    # skipping the entry.
    MODEL_CHECK_CORPUS = Hecks::Corpus.model_check_members
                                      .map { |member| [member.stem, Hecks::Corpus.source_of(member)] }.freeze

    # The SAME constant bin/model_check reads — one table, not a copy.
    MODEL_CHECK_ALLOWED = Hecks::Bluebook::ModelCheck::ALLOWED_FINDINGS

    # TWO PASSES OVER THE SAME BOOTS — the identical structure
    # bin/model_check's own main loop takes, own comment there. Every
    # corpus member's own bluebook/hecksagon name has to be known before
    # ANY member's own cross-domain check can trust "this target isn't
    # anywhere in the corpus" — a single member's own boot (Compliance
    # never loaded in the same registry as Banking, by design) cannot
    # answer that alone. Computed lazily, once, on first use (not at
    # class-body/file-load time) and memoized — every corpus member gets
    # re-booted once more per `it` below regardless (each test needs its
    # own fresh registry the same way it always did), so this only adds
    # ONE extra full boot pass, not one per example.
    def self.known_domains
      @known_domains ||= MODEL_CHECK_CORPUS.flat_map do |_, source|
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          InMemoryDomain.load_bluebook_files(source)
        end
        registry.bluebooks.keys + registry.hecksagons.keys
      end.to_set.freeze
    end

    MODEL_CHECK_CORPUS.each do |name, source|
      it "#{name} has no error bin/model_check does not already name" do
        # Same Rust-target inference bin/model_check#examine makes, so a
        # reserved-name collision in a Rust-built corpus domain is an error here too.
        rust_target = Hecks::Fuzzing::TargetCapabilities.rust_feature?(name, File.join(ROOT_DIR, "rust"))
        registry = boot(source)
        bluebook = registry.bluebooks.values.first
        findings = Hecks::Bluebook::ModelCheck.call(bluebook, hecksagon:     registry.hecksagon(bluebook.name),
                                                              known_domains: self.class.known_domains,
                                                              rust_target:   rust_target)
        errors   = findings.select { |f| f.severity == :error }
        allowed  = MODEL_CHECK_ALLOWED.fetch(name, [])

        unnamed = errors.reject { |f| allowed.include?([f.kind, f.subject]) }
        expect(unnamed).to be_empty, unnamed.join("\n")
      end
    end

    it "names nothing in the allowlist that the checker no longer finds" do
      MODEL_CHECK_ALLOWED.each do |name, entries|
        source = MODEL_CHECK_CORPUS.to_h.fetch(name) { next }
        findings = call_model_check(boot(source), known_domains: self.class.known_domains)
        found = findings.select { |f| f.severity == :error }.map { |f| [f.kind, f.subject] }

        stale = entries - found
        expect(stale).to be_empty, "#{name}: #{stale.inspect} no longer found — delete from ALLOWED_FINDINGS"
      end
    end

    # PINNED EMPTY, the way bin/fuzz's KNOWN_FUZZ_FINDINGS is — a domain
    # that means to keep a finding declares it in its own source (banking's
    # `across "Notifications", expect_undelivered: true`), never here.
    it "keeps the core allowlist empty" do
      expect(MODEL_CHECK_ALLOWED).to eq({})
    end

    describe "a declared undelivered across target" do
      let(:banking) { MODEL_CHECK_CORPUS.to_h.fetch("banking") }

      it "is what keeps banking's two Notifications policies clean" do
        declared = boot(banking).bluebook("Banking").policies.select(&:expect_undelivered).map(&:name).sort
        expect(declared).to eq(%w[FlagKeyReturn NotifyOnClosure])

        errors = call_model_check(boot(banking), known_domains: self.class.known_domains)
                 .select { |f| %w[FlagKeyReturn NotifyOnClosure].include?(f.subject) }
        expect(errors).to be_empty
      end

      it "fails as stale once the target is a domain the corpus actually boots" do
        known    = self.class.known_domains | ["Notifications"]
        findings = call_model_check(boot(banking), known_domains: known)
        stale    = findings.select { |f| f.kind == :stale_undelivered_expectation }

        expect(stale.map(&:subject).sort).to eq(%w[FlagKeyReturn NotifyOnClosure])
        expect(stale.map(&:severity).uniq).to eq([:error])
      end

      it "raises the ordinary findings again once the declaration is dropped" do
        registry = boot(banking)
        registry.bluebook("Banking").policies.select(&:expect_undelivered).each do |policy|
          policy.instance_variable_set(:@expect_undelivered, false)
        end
        kinds = call_model_check(registry, known_domains: self.class.known_domains)
                .select { |f| f.subject == "NotifyOnClosure" }.map(&:kind).sort

        expect(kinds).to eq(%i[unacknowledged_relationship unknown_target_domain])
      end
    end

    it "the language itself is clean" do
      %w[Bluebook World].each do |name|
        chapter = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook(name)
        next unless chapter

        errors = Hecks::Bluebook::ModelCheck.call(chapter).select { |f| f.severity == :error }
        expect(errors).to be_empty, errors.join("\n")
      end
    end
  end
end
