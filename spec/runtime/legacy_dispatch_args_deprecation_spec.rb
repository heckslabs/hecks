require "spec_helper"
require_relative "../support/legacy_dispatch_sites"

# Roadmap I3 — command facts passed to `dispatch` as loose keyword
# arguments are deprecated in favor of `to:` / `with:`, and removed in
# Dispatcher::LEGACY_ARGS_REMOVAL. spec_helper.rb arms the deprecation to
# RAISE at any site not already counted in spec/support/legacy_dispatch_
# sites.rb; this file is the one place the shape is exercised on purpose,
# so it arms and disarms that setting explicitly around each example
# rather than living under whatever the suite happens to have set.
RSpec.describe "Loose keyword facts in dispatch (deprecated)" do
  LEGACY_DISPATCH_PIZZA_FACTS = { name:  { value: "Margherita" },
                                  pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }.freeze
  LEGACY_DISPATCH_WARNING =
    /passing command facts to dispatch as loose keyword arguments is deprecated and will be removed in hecks #{
      Regexp.escape(Hecks::Runtime::Dispatcher::LEGACY_ARGS_REMOVAL)}/

  let(:runtime) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Hecks.hecksagon("Pizzas") do
        uses_framework "Governance"
        Pizzas::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecks::Runtime::Dispatcher.new(registry)
  end

  # Every example sets the deprecation's own mode and hands the suite's
  # back afterwards — `nil` for the warning an application sees, a block
  # for where it raises.
  def deprecation_mode(where = nil)
    Hecks::Deprecation.raising.delete(:legacy_dispatch_args)
    Hecks::Deprecation.raise_on!(:legacy_dispatch_args, &where) if where
    Hecks::Deprecation.reset!
    yield
  ensure
    Hecks::Deprecation.raising.delete(:legacy_dispatch_args)
    LegacyDispatchSites.install_suite_guard!
    Hecks::Deprecation.reset!
  end

  it "names the removal release in Dispatcher::LEGACY_ARGS_REMOVAL" do
    expect(Hecks::Runtime::Dispatcher::LEGACY_ARGS_REMOVAL).to eq("1.5.0")
  end

  it "warns once per call site, at that site, and still dispatches" do
    deprecation_mode do
      line = __LINE__ + 3
      results = []
      expect do
        2.times { |n| results << runtime.dispatch("Pizzas::Order.CreatePizza", name: { value: "p#{n}" }, pizza: LEGACY_DISPATCH_PIZZA_FACTS[:pizza]) }
      end.to output(/\A#{Regexp.escape(__FILE__)}:#{line}: warning: #{LEGACY_DISPATCH_WARNING.source}[^\n]*\n\z/o).to_stderr

      expect(results.map(&:id)).to eq(%w[p0 p1])
    end
  end

  it "stays silent for to: / with:" do
    deprecation_mode do
      expect do
        runtime.dispatch("Pizzas::Order.CreatePizza", with: LEGACY_DISPATCH_PIZZA_FACTS)
        runtime.dispatch("Pizzas::Order.AddTopping", to:   "Margherita",
                                                     with: { topping: { value: "Basil" }, amount: { value: 3 } })
      end.not_to output.to_stderr
    end
  end

  it "stays silent for the flat-facts wire form framework replays use" do
    deprecation_mode do
      expect { runtime.dispatch_flat("Pizzas::Order.CreatePizza", LEGACY_DISPATCH_PIZZA_FACTS) }.not_to output.to_stderr
    end
  end

  it "is silenced by HECKS_SILENCE_DEPRECATIONS=1" do
    deprecation_mode do
      ENV["HECKS_SILENCE_DEPRECATIONS"] = "1"
      expect { runtime.dispatch("Pizzas::Order.CreatePizza", **LEGACY_DISPATCH_PIZZA_FACTS) }.not_to output.to_stderr
    ensure
      ENV.delete("HECKS_SILENCE_DEPRECATIONS")
    end
  end

  it "raises where it is armed to, naming the caller's own line" do
    deprecation_mode(Hecks::Deprecation::EVERYWHERE) do
      line = __LINE__ + 1
      expect { runtime.dispatch("Pizzas::Order.CreatePizza", **LEGACY_DISPATCH_PIZZA_FACTS) }
        .to raise_error(Hecks::Deprecation::Error, /\A#{Regexp.escape(__FILE__)}:#{line}: #{LEGACY_DISPATCH_WARNING.source}/o)
    end
  end

  it "is suppressed inside Hecks::Deprecation.allowing, even while raising" do
    deprecation_mode(Hecks::Deprecation::EVERYWHERE) do
      result = Hecks::Deprecation.allowing(:legacy_dispatch_args) do
        runtime.dispatch("Pizzas::Order.CreatePizza", **LEGACY_DISPATCH_PIZZA_FACTS)
      end
      expect(result.id).to eq("Margherita")
    end
  end

  # What spec_helper.rb actually arms: raise at a site nothing counted,
  # stay a warning at one the worklist knows about, so the suite refuses
  # NEW loose calls without pretending the old ones are gone.
  it "raises for the suite only where no counted site exists" do
    counted = LegacyDispatchSites::CAPS.keys.first
    expect(LegacyDispatchSites.known?("#{counted}:12")).to be(true)
    expect(LegacyDispatchSites.known?("spec/a_spec_nobody_has_written_yet.rb:12")).to be(false)
    expect(LegacyDispatchSites.known?("#{LegacyDispatchSites::ROOT}/#{counted}:12")).to be(true)
  end
end
