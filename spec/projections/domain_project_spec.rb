require "spec_helper"
require "json"
require "tmpdir"

# The domain-facing `project` verb, which hands a projector the booted domain's Bluebook.
# Booted in memory (boot_in_memory): no adapter is touched.
RSpec.describe "Domain.project" do
  let(:runtime)  { boot_in_memory }
  let(:bluebook) { runtime.registry.bluebook("Pizzas") }
  let(:domain) do
    runtime
    Object.const_get("Pizzas")
  end

  describe "addressing a target" do
    it "takes the constant form" do
      expect(domain.project(Hecks::Projections::IR)).to eq(bluebook.to_h)
    end

    # The constant spelling must mean the same as Projector.call(:ir, ...).
    it "takes the bare symbol form, and both answer identically" do
      expect(domain.project(:ir)).to eq(domain.project(Hecks::Projections::IR))
    end

    it "refuses an unregistered target, naming what IS registered" do
      expect { domain.project(:nonexistent) }
        .to raise_error(Hecks::Projector::UnknownProjector, /nonexistent/)
    end
  end

  describe "options" do
    # `project` knows `out:` only; the rest is the target's own vocabulary.
    it "passes unknown keywords through to the projector untouched" do
      projected = domain.project(Hecks::Projections::OIDC, audience: "https://api.example.com")

      expect(projected["audience"]).to eq("https://api.example.com")
    end
  end

  describe "out:" do
    it "is pure without it — the artifact comes back and nothing is written" do
      Dir.mktmpdir do |dir|
        domain.project(Hecks::Projections::OIDC)

        expect(Dir.children(dir)).to be_empty
      end
    end

    it "writes JSON and answers with the path when given one" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "oidc.json")

        expect(domain.project(Hecks::Projections::OIDC, out: path)).to eq(path)
        expect(JSON.parse(File.read(path))).to eq(JSON.parse(JSON.generate(domain.project(Hecks::Projections::OIDC))))
      end
    end

    it "writes a String artifact verbatim rather than as JSON" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "raw.txt")
        Hecks::Projector.register(:stub_text, Class.new do
          def self.call(bluebook:, options: {}) = "just text, not #{bluebook.name.inspect} as JSON"
        end)

        domain.project(:stub_text, out: path)

        expect(File.read(path)).to eq('just text, not "Pizzas" as JSON')
      ensure
        Hecks::Projector.registry.delete(:stub_text)
      end
    end
  end

  # `to_ir` is absent on purpose: `project(IR)` already answers the canonical serialized form.
  it "exposes no second way to reach the IR" do
    expect(domain).not_to respond_to(:to_ir)
  end

  # Handing a chapter-scoped projector an aggregate must raise: `StorageShape.project` would
  # otherwise read a missing `aggregates` key and answer a well-formed, wrong result.
  describe "an aggregate door" do
    let(:order) do
      runtime
      Object.const_get("Pizzas::Order")
    end

    it "projects its OWN IR, not its chapter's" do
      expect(order.project(Hecks::Projections::IR)).to eq(order.ir.to_h)
      expect(order.project(Hecks::Projections::IR)).not_to eq(domain.project(Hecks::Projections::IR))
    end

    it "refuses a target whose capability it lacks, instead of answering emptily" do
      expect { order.project(Hecks::Projections::Shape) }
        .to raise_error(Hecks::Projector::WrongConstruct, /Behaviour::Chapter/)
    end

    it "names the construct it was actually handed, so the refusal is actionable" do
      expect { order.project(Hecks::Projections::OIDC) }
        .to raise_error(Hecks::Projector::WrongConstruct, /Order/)
    end
  end

  describe "emits: :files" do
    it "writes a tree and answers with the paths, rather than one JSON blob" do
      Dir.mktmpdir do |dir|
        tree = Module.new do
          extend Hecks::Projector::Target

          projects_as :tree_stub, emits: :files
          def self.call(bluebook:, options: {}) = { "a.txt" => "one", "nested/b.txt" => "two" }
        end

        written = Hecks::Projector.write(
          Hecks::Projector.call(:tree_stub, bluebook: bluebook), dir, as: :files
        )

        expect(written.map { |p| p.sub("#{dir}/", "") }).to eq(["a.txt", "nested/b.txt"])
        expect(File.read(File.join(dir, "nested/b.txt"))).to eq("two")
        tree
      ensure
        Hecks::Projector.registry.delete(:tree_stub)
      end
    end

    # The kind is declared, never inferred: a Hash of path => contents and a Hash that merely
    # holds strings look the same to Ruby.
    it "asks the projection what it emits rather than inspecting the artifact" do
      expect(Hecks::Projector.emits_for(:reference)).to eq(:files)
      expect(Hecks::Projector.emits_for(:vocabulary)).to eq(:artifact)
    end
  end

  describe "capabilities" do
    # `requires:` names a capability module (Hecks::IR, Behaviour::Chapter), not a shape word.
    it "lets a target requiring only the IR capability run on any construct that emits" do
      expect(Hecks::Projections::IR.projection_requires).to eq([Hecks::IR])
      expect { Object.const_get("Pizzas::Order").project(Hecks::Projections::IR) }.not_to raise_error
    end

    # Class-shaped constructs extend capabilities; `is_a?` consults the singleton chain, so one
    # check covers both shapes.
    it "sees a capability a class-shaped construct extends" do
      command = bluebook.aggregate("Order").commands.first

      expect(command).to be_a(Class)
      expect(Hecks::Projector.capable?(command, Hecks::IR)).to be true
    end

    # Defaulting to the chapter capability keeps the check safe; a permissive default would
    # preserve the fail-quiet.
    it "defaults an undeclared target to the chapter capability" do
      legacy = Module.new do
        extend Hecks::Projector::Target

        def self.call(bluebook:, options: {}) = :ran
      end
      legacy.projects_as :legacy_capability_stub

      expect(legacy.projection_requires).to eq([Hecks::Bluebook::Behaviour::Chapter])
      expect { Hecks::Projector.call(:legacy_capability_stub, bluebook: Object.const_get("Pizzas::Order").ir) }
        .to raise_error(Hecks::Projector::WrongConstruct)
    ensure
      Hecks::Projector.registry.delete(:legacy_capability_stub)
    end
  end

  # The registry-first path suits order-sensitive callers: Facade::Namespace.install keeps a
  # pre-existing constant (a domain named `Set` gets none) and a prior boot's module can linger.
  it "agrees with calling the registry directly, without any constant" do
    expect(Hecks::Projector.call(:oidc, bluebook: bluebook))
      .to eq(domain.project(Hecks::Projections::OIDC))
  end
end
