require "spec_helper"
require "tmpdir"

# ADR 0025's second Wave-0 prerequisite (docs/dsl-work-slices.md, S0b):
# without this, first-class events and command references (S6, S7) and
# a constant-typed `admits:` (S3's own half) cannot be spelled as
# constants at all — `Account::Debit` needs `Account` to answer `::`,
# which a bare Symbol (today's whole answer, bluebook_builder.rb's own
# former `resolver = ->(const) { const }`) cannot do.
#
# THE RISK NAMED IN THE DOC, verified here rather than assumed: "a real
# facade method colliding with a declaration-time constant... the
# scenario that broke the earlier attempt was two domains in one
# registry." `attribute_collector.rb`'s own comment on `admits:` records
# that earlier attempt's exact failure — a Module-returning shim worked
# only until ANY facade existed, because `Facade::Surface` installs
# every aggregate name as a TOP-LEVEL constant (both nested under its
# chapter AND bare), so the shim was then simply never reached again.
#
# Fixture names are deliberately unlike anything else in the corpus
# (`ScopedBridge*`) — `Facade::Surface.install` sets REAL top-level
# Ruby constants that outlive this example, in a suite that shares one
# process across every spec file; a generic name ("Widget", "Thing")
# risks colliding with some other file's own fixture.
RSpec.describe "the scoped-constant bridge" do
  ScopedConstant = Hecksagain::Bluebook::DSL::ConstShim::ScopedConstant

  DOMAIN_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "ScopedBridgeDomain" do
      vision "domain A — boots first, and its facade becomes real"
      generic

      aggregate "ScopedBridgeThing" do
        identified_by { name.value }

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

  def boot_domain(root)
    domain_dir = File.join(root, "bluebook")
    FileUtils.mkdir_p(domain_dir)
    File.write(File.join(domain_dir, "scoped_bridge_domain.bluebook"), DOMAIN_SOURCE)

    registry = Hecksagain::Runtime::Registry.new(root: root)
    loading  = Hecksagain::Ports::Loading.bootstrap
    Hecksagain.with_registry(registry) do
      loading.load_library
      Kernel.load(File.join(domain_dir, "scoped_bridge_domain.bluebook"))
    end
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    registry
  end

  def with_declaration_resolver
    resolver = ->(const) { ScopedConstant.for(const) }
    Hecksagain::Bluebook::DSL::ConstShim.with(resolver) { yield }
  end

  describe "ScopedConstant itself" do
    it "chains indefinitely, reading back the full dotted path" do
      scoped = ScopedConstant.for("Account")
      expect(scoped.to_s).to eq("Account")

      deeper = scoped::Debit
      expect(deeper.to_s).to eq("Account::Debit")
      expect(deeper).to be_a(Module)
    end

    it "duck-types as the bareword symbol it replaces, for a single segment" do
      scoped = ScopedConstant.for("PizzaName")

      expect(scoped.to_sym).to eq(:PizzaName)
      expect(Hecksagain::Naming.demodulise(scoped)).to eq("PizzaName")
      expect(scoped.to_s[0]).to match(/[A-Z]/)
    end
  end

  # `Account::Debit` written from WITHIN the domain that declares
  # `Account`, before that domain's own facade exists at all — the
  # common case, and the one every existing corpus bluebook would hit
  # first if S6/S7 used this today.
  it "resolves a scoped reference with no facade in the picture yet" do
    result = with_declaration_resolver { ScopedBridgeFreshDomain::Something }

    expect(result.to_s).to eq("ScopedBridgeFreshDomain::Something")
  end

  # THE COLLISION THE DOC NAMES. `Surface.install` installs an
  # aggregate's OWN name as a bare top-level constant (surface.rb's own
  # `install`), not only nested under its chapter — so once the domain
  # has booted once in this process, `ScopedBridgeThing::Make` written
  # while declaring some OTHER domain reaches the aggregate DOOR's own
  # const_missing directly; `Object.const_missing`/`ConstShim::Hook` is
  # never asked at all, because the name is no longer missing.
  it "resolves a scoped reference through a REAL, already-installed facade module" do
    Dir.mktmpdir do |root|
      boot_domain(root)
      expect(defined?(ScopedBridgeThing)).to be_truthy

      result = with_declaration_resolver { ScopedBridgeThing::Make }
      expect(result.to_s).to eq("ScopedBridgeThing::Make")
      expect(result).to be_a(ScopedConstant)
    end
  end

  # "a real facade method with a colliding name still works" — the
  # regression the fix must never cause: a genuine existing constant or
  # method resolves through ORDINARY Ruby lookup, never reaching
  # const_missing, so nothing here can shadow it.
  it "never shadows a real facade constant or method with the same name" do
    Dir.mktmpdir do |root|
      boot_domain(root)

      nested = with_declaration_resolver { ScopedBridgeDomain::ScopedBridgeThing }
      expect(nested).to be_a(Module)
      expect(nested).not_to be_a(ScopedConstant) # a REAL constant, found without const_missing at all

      expect(ScopedBridgeThing.commands).to eq(["make"])
    end
  end

  # THE ADVERSARIAL CASE, TWO DOMAINS IN ONE REGISTRY: boot A, then
  # declare a SECOND domain B that references A's aggregate by name —
  # cross-domain, after A's facade is already real, inside a fresh
  # ConstShim-active declaration of its own.
  it "resolves a cross-domain reference declared AFTER the referenced domain already booted" do
    Dir.mktmpdir do |root|
      boot_domain(root)

      result = with_declaration_resolver { ScopedBridgeThing::Make }
      expect(result.to_s).to eq("ScopedBridgeThing::Make")

      # B's own declaration still resolves its OWN barewords normally,
      # unaffected by A sharing the same ConstShim-active window.
      own = with_declaration_resolver { ScopedBridgeSomethingLocalToB }
      expect(own.to_s).to eq("ScopedBridgeSomethingLocalToB")
    end
  end
end
