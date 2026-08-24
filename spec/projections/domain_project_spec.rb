require "spec_helper"
require "json"
require "tmpdir"

# THE DOMAIN-FACING VERB. `Projector.call(name, bluebook:, options:)` has
# existed since §30 but nothing could reach it from a booted domain — the
# chapter module closed over the one Bluebook every projector wants
# and never handed it out, so each bin/ projector rebuilt a Registry and
# reloaded the files to recover what was already in scope.
#
# Booted in memory (spec_helper's own boot_in_memory) rather than against
# examples/pizzas/data — this touches no adapter and should not need one.
RSpec.describe "Domain.project" do
  let(:runtime)  { boot_in_memory }
  let(:bluebook) { runtime.registry.bluebook("Pizzas") }
  let(:domain)   { runtime; Object.const_get("Pizzas") }

  describe "addressing a target" do
    it "takes the constant form" do
      expect(domain.project(Hecks::Projections::IR)).to eq(bluebook.to_h)
    end

    # The constant spelling is ADDED surface, not a replacement — every
    # Projector.call(:ir, ...) written before it keeps working, and the
    # two must not be allowed to mean different things.
    it "takes the bare symbol form, and both answer identically" do
      expect(domain.project(:ir)).to eq(domain.project(Hecks::Projections::IR))
    end

    it "refuses an unregistered target, naming what IS registered" do
      expect { domain.project(:nonexistent) }
        .to raise_error(Hecks::Projector::UnknownProjector, /nonexistent/)
    end
  end

  describe "options" do
    # `project` knows `out:` and nothing else — everything remaining is
    # the TARGET's own vocabulary, so a projector can grow an option
    # without this method learning about it.
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
        Hecks::Projector.register(:stub_text, Class.new {
          def self.call(bluebook:, options: {}) = "just text, not #{bluebook.name.inspect} as JSON"
        })

        domain.project(:stub_text, out: path)

        expect(File.read(path)).to eq('just text, not "Pizzas" as JSON')
      ensure
        Hecks::Projector.registry.delete(:stub_text)
      end
    end
  end

  # The reason `to_ir` is deliberately absent: one verb, and the
  # canonical serialized form is what `project(IR)` already answers.
  it "exposes no second way to reach the IR" do
    expect(domain).not_to respond_to(:to_ir)
  end

  # PER-CONSTRUCT PROJECTION, and the fail-quiet it closed.
  #
  # Every construct emits its own IR (Hecks::IR), so an aggregate is
  # a legitimate thing to project. But `bluebook:` was only ever a
  # parameter NAME — nothing checked what arrived — and a chapter-scoped
  # projector handed an aggregate did not crash: `StorageShape.project`
  # reads `domain["aggregates"] || []`, a key an aggregate's IR does not
  # carry, and answered `{"name" => "Order", "aggregates" => []}`.
  # Well-formed, confident, wrong.
  describe "an aggregate door" do
    let(:order) { runtime; Object.const_get("Pizzas::Order") }

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

  # THE TREE CASE, which the output contract was designed for and left
  # unimplemented until a projection genuinely emitted one.
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

    # The kind is DECLARED, never inferred: a Hash of path => contents and
    # a Hash that merely holds strings are the same object to Ruby.
    it "asks the projection what it emits rather than inspecting the artifact" do
      expect(Hecks::Projector.emits_for(:reference)).to eq(:files)
      expect(Hecks::Projector.emits_for(:vocabulary)).to eq(:artifact)
    end
  end

  describe "capabilities" do
    # `requires:` names a MODULE, not a shape word. The capabilities were
    # already real — Hecks::IR is the ability to emit IR, and
    # Behaviour::Chapter the ability to answer as a chapter — so a
    # projection names what it needs rather than a symbol standing in
    # for it.
    it "lets a target requiring only the IR capability run on any construct that emits" do
      expect(Hecks::Projections::IR.projection_requires).to eq([Hecks::IR])
      expect { Object.const_get("Pizzas::Order").project(Hecks::Projections::IR) }.not_to raise_error
    end

    # A class-shaped construct EXTENDS its capabilities rather than
    # including them. `is_a?` consults the singleton chain, so one check
    # covers both shapes — asserting otherwise is what showed the second
    # check was dead.
    it "sees a capability a class-shaped construct extends" do
      command = bluebook.aggregate("Order").commands.first

      expect(command).to be_a(Class)
      expect(Hecks::Projector.capable?(command, Hecks::IR)).to be true
    end

    # Defaulting to the chapter capability is what makes the check safe
    # for a target written before `requires:` existed — guessing the
    # permissive answer would preserve the fail-quiet it closes.
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

  # The registry-first path stays available and is what anything
  # order-sensitive should use — Facade::Namespace.install warns and
  # KEEPS a pre-existing constant rather than clobbering it, so a domain
  # named `Set` never gets a constant at all, and a prior boot's module
  # can linger on Object.
  it "agrees with calling the registry directly, without any constant" do
    expect(Hecks::Projector.call(:oidc, bluebook: bluebook))
      .to eq(domain.project(Hecks::Projections::OIDC))
  end
end
