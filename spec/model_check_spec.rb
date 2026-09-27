require "spec_helper"
require "hecks/bluebook/model_check"
require "hecks/fuzzing/target_capabilities"
require "tmpdir"

# Model-checks lifecycles and process managers: unreachable states, dead transitions,
# unreachable compensations, dispatches to nowhere, handlers for events nothing emits.
RSpec.describe "the model checker" do
  ROOT_DIR = InMemoryDomain::ROOT unless defined?(ROOT_DIR)

  def boot(bluebook)
    # `root:` lets a corpus member using `uses_embryonaut_bluebook` vendor from its own root
    # (the parent of its `bluebook/` folder); a bare `.bluebook` file has none.
    root = File.directory?(bluebook) ? File.dirname(bluebook) : nil
    registry = Hecks::Runtime::Registry.new(root: root)
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(bluebook)

      # The sibling hecksagon(s), if any, as in bin/model_check; fixtures have none.
      hecksagons = if File.directory?(bluebook)
                     Dir.glob(File.join(bluebook, "*.hecksagon"))
                   else
                     [bluebook.sub(/\.bluebook\z/, ".hecksagon")]
                   end
      hecksagons.each { |hecksagon| Kernel.load(hecksagon) if File.exist?(hecksagon) }
    end
    registry
  end

  # Returns the registry: callers also need `registry.hecksagon(bluebook.name)` for the
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
      # Not an exact count: "Vanish" cascades into a second unreachable_state and a stuck_state.
      # The fixture proves each kind fires at least once, not how many a hand-written FSM yields.
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

    # A policy triggering an `asks`/`tells` port operation (three segments) is not an
    # `unknown_trigger`; qa/bluebook/quality_control.bluebook's FileWhenSubmitted is the real case.
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
      # With a cross-domain policy but no sibling hecksagon (every other fixture's shape),
      # neither new finding is raised: the `return [] unless hecksagon` guard.
      no_hecksagon_findings = call_model_check(boot(File.join(ROOT_DIR, "spec/fixtures/model_check/policy_findings.bluebook")))
      expect(no_hecksagon_findings.map(&:kind)).not_to include(:contradictory_relationship, :unacknowledged_relationship)
    end
  end

  # A Rust keyword as a domain or aggregate name, or a reserved Cargo.toml key as a domain
  # module/feature key: a warning by default, an error with a Rust target or strict.
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

  # The coverage gate: the real corpus stays finding-free against bin/model_check's allowlist.
  # An unlisted reported error, or a stale allowlist entry, fails.
  describe "the real corpus" do
    # The same kinds bin/model_check walks, from the one table both read (Hecks::Corpus).
    MODEL_CHECK_CORPUS = Hecks::Corpus.model_check_members
                                      .map { |member| [member.stem, Hecks::Corpus.source_of(member)] }.freeze

    # The same constant bin/model_check reads — one table, not a copy.
    MODEL_CHECK_ALLOWED = Hecks::Bluebook::ModelCheck::ALLOWED_FINDINGS

    # Two passes over the same boots, as in bin/model_check: a cross-domain check needs every
    # corpus member's domain name known first. Computed lazily and memoized.
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

    # Pinned empty: a domain that keeps a finding declares it in its own source, never here.
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
