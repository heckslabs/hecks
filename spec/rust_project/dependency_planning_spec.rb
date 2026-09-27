require "spec_helper"
require "json"
require_relative "../../rust/project"

# `state_independent_creation?` is an independent port of the Analyzer's
# `complete_state? && state_independent?`; this checks it agrees with the live Analyzer.
RSpec.describe "RustProjection::Projector.state_independent_creation? matches the live Analyzer" do
  def self.json_shaped(payload) = JSON.parse(JSON.generate(payload), symbolize_names: true)

  # Returns [registry, bluebook, IR hash]: live objects for the Analyzer, JSON IR for the port.
  def self.load_domain(bluebook_path, domain_name)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
      InMemoryDomain.load_bluebook_files(bluebook_path)
    end
    bluebook = registry.bluebooks.fetch(domain_name)
    ir = json_shaped(Hecks::Projector::Exporter.call(registry).fetch(domain_name))
    [registry, bluebook, ir]
  end

  # Every corpus domain with a `creates?`-true aggregate-root command declaring a `given`,
  # plus the self-hosted grammar, Banking (`Account.Open`) and ReferralChain (`Member.Join`).
  DEPENDENCY_PLANNING_CORPUS = [
    ["Pizzas", -> { load_domain(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"), "Pizzas") }],
    ["Compliance", lambda {
      load_domain(File.join(InMemoryDomain::ROOT, "examples/compliance/bluebook/compliance.bluebook"), "Compliance")
    }],
    ["Roster", -> { load_domain(File.join(InMemoryDomain::ROOT, "examples/roster/bluebook/roster.bluebook"), "Roster") }],
    ["Banking", -> { load_domain(InMemoryDomain::BANKING_BLUEBOOK_DIR, "Banking") }],
    ["ReferralChain", lambda {
      load_domain(File.join(InMemoryDomain::ROOT, "qa/stress_domains/referral_chain/bluebook"), "ReferralChain")
    }],
    ["Bluebook", lambda {
      meta = Hecks::Bluebook::MetaValidator.grammar_registry
      [meta, meta.bluebook("Bluebook"), json_shaped(Hecks::Projector::Exporter.call(meta).fetch("Bluebook"))]
    }]
  ].freeze

  DEPENDENCY_PLANNING_CORPUS.each do |name, loader|
    describe name do
      it "agrees with Runtime::DependencyPlanning::Analyzer for every creates?-true aggregate-root command" do
        _registry, bluebook, ir = loader.call
        checked = 0

        bluebook.aggregates.zip(ir[:aggregates]).each do |aggregate, aggregate_ir|
          domain_value_objects_by_name = ir[:aggregates].flat_map { |a| a[:value_objects] }.to_h { |vo| [vo[:name], vo] }
          value_objects_by_name = domain_value_objects_by_name.merge(aggregate_ir[:value_objects].to_h { |vo| [vo[:name], vo] })

          aggregate.commands.zip(aggregate_ir[:commands]).each do |command, command_ir|
            next unless command.creates?

            checked += 1
            plan = Hecks::Runtime::DependencyPlanning::Analyzer.call(aggregate: aggregate, command: command)
            expected = plan.complete_state? && plan.state_independent?
            actual = RustProjection::Projector.state_independent_creation?(aggregate_ir, command_ir, value_objects_by_name)

            expect(actual).to eq(expected),
                              "#{aggregate.hecks_name}.#{command.hecks_name}: expected state_independent_creation? " \
                              "to be #{expected} (Runtime::DependencyPlanning::Analyzer: complete_state?=" \
                              "#{plan.complete_state?}, state_independent?=#{plan.state_independent?}), got #{actual}"

            # `complete_state?` alone decides whether a routed creating command is checked
            # against its derived identity or falls back to find-or-NotFound.
            complete_actual = RustProjection::Projector.complete_state_creation?(aggregate_ir, command_ir, value_objects_by_name)
            expect(complete_actual).to eq(plan.complete_state?),
                                       "#{aggregate.hecks_name}.#{command.hecks_name}: expected " \
                                       "complete_state_creation? to be #{plan.complete_state?} " \
                                       "(Runtime::DependencyPlanning::Analyzer), got #{complete_actual}"
          end
        end

        expect(checked).to be > 0, "#{name}: found no creates?-true aggregate-root command — this corpus member " \
                                   "isn't exercising anything, fix the enumeration"
      end
    end
  end
end
