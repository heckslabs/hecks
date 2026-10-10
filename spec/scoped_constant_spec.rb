require "spec_helper"
require "tmpdir"

# Constants like `Account::Debit` must resolve at declaration time (ADR 0025, S0b), including
# with two domains in one registry, where an installed facade constant hides the shim.
#
# Fixture names (`ScopedBridge*`) are unusual on purpose: `Adapters::Driving::Ruby.install` sets real
# top-level constants that outlive each example in a shared process.
RSpec.describe "the scoped-constant bridge" do
  ScopedConstant = Hecks::Bluebook::DSL::ConstShim::ScopedConstant

  DOMAIN_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "ScopedBridgeDomain" do
      vision "domain A — boots first, and its facade becomes real"
      generic

      aggregate "ScopedBridgeThing" do
        identified_by :name

        attribute :name, ScopedBridgeThingName

        value_object "ScopedBridgeThingName" do
          attribute :value, String
        end

        command "Make" do
          attribute :name, ScopedBridgeThingName
          emits "Made"
        end
      end
    end
  BLUEBOOK

  def write_domain(root)
    domain_dir = File.join(root, "bluebook")
    FileUtils.mkdir_p(domain_dir)
    File.join(domain_dir, "scoped_bridge_domain.bluebook").tap { |file| File.write(file, DOMAIN_SOURCE) }
  end

  def boot_domain(root)
    file = write_domain(root)
    registry = Hecks::Runtime::Registry.new(root: root)
    loading  = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.load(file)
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    registry
  end

  def with_declaration_resolver(&block)
    resolver = ->(const) { ScopedConstant.for(const) }
    Hecks::Bluebook::DSL::ConstShim.with(resolver, &block)
  end

  describe "ScopedConstant itself" do
    it "chains indefinitely, reading back the full dotted path", :aggregate_failures do
      scoped = ScopedConstant.for("Account")
      expect(scoped.to_s).to eq("Account")

      deeper = scoped::Debit
      expect(deeper.to_s).to eq("Account::Debit")
      expect(deeper).to be_a(Module)
    end

    it "duck-types as the bareword symbol it replaces, for a single segment", :aggregate_failures do
      scoped = ScopedConstant.for("PizzaName")

      expect(scoped.to_sym).to eq(:PizzaName)
      expect(Hecks::Naming.demodulise(scoped)).to eq("PizzaName")
      expect(scoped.to_s[0]).to match(/[A-Z]/)
    end
  end

  # The common case: a scoped reference written before the declaring domain's facade exists.
  it "resolves a scoped reference with no facade in the picture yet" do
    result = with_declaration_resolver { ScopedBridgeFreshDomain::Something }

    expect(result.to_s).to eq("ScopedBridgeFreshDomain::Something")
  end

  context "with a domain booted in a scratch directory" do
    around do |example|
      Dir.mktmpdir do |root|
        boot_domain(root)
        example.run
      end
    end

    # `Ruby.install` also installs each aggregate as a bare top-level constant, so after a
    # boot `ScopedBridgeThing::Make` reaches the aggregate's const_missing, never `ConstShim::Hook`.
    it "resolves a scoped reference through a REAL, already-installed facade module", :aggregate_failures do
      expect(defined?(ScopedBridgeThing)).to be_truthy

      result = with_declaration_resolver { ScopedBridgeThing::Make }
      expect(result.to_s).to eq("ScopedBridgeThing::Make")
      expect(result).to be_a(ScopedConstant)
    end

    # A genuine existing constant or method resolves by ordinary lookup; the shim never shadows it.
    it "never shadows a real facade constant or method with the same name", :aggregate_failures do
      nested = with_declaration_resolver { ScopedBridgeDomain::ScopedBridgeThing }
      expect(nested).to be_a(Module)
      # a real constant, found without const_missing at all
      expect(nested).not_to be_a(ScopedConstant)

      expect(ScopedBridgeThing.commands).to eq(["make!"])
    end

    # Two domains in one registry: domain B references A's aggregate after A's facade is real.
    it "resolves a cross-domain reference declared AFTER the referenced domain already booted", :aggregate_failures do
      result = with_declaration_resolver { ScopedBridgeThing::Make }
      expect(result.to_s).to eq("ScopedBridgeThing::Make")

      # B's own barewords still resolve normally.
      own = with_declaration_resolver { ScopedBridgeSomethingLocalToB }
      expect(own.to_s).to eq("ScopedBridgeSomethingLocalToB")
    end
  end
end
