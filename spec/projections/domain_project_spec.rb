require "spec_helper"
require "json"
require "tmpdir"

# THE DOMAIN-FACING VERB. `Projector.call(name, bluebook:, options:)` has
# existed since §30 but nothing could reach it from a booted domain — the
# chapter module closed over the one IR::Bluebook every projector wants
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
      expect(domain.project(Hecksagain::Projections::IR)).to eq(bluebook.to_h)
    end

    # The constant spelling is ADDED surface, not a replacement — every
    # Projector.call(:ir, ...) written before it keeps working, and the
    # two must not be allowed to mean different things.
    it "takes the bare symbol form, and both answer identically" do
      expect(domain.project(:ir)).to eq(domain.project(Hecksagain::Projections::IR))
    end

    it "refuses an unregistered target, naming what IS registered" do
      expect { domain.project(:nonexistent) }
        .to raise_error(Hecksagain::Projector::UnknownProjector, /nonexistent/)
    end
  end

  describe "options" do
    # `project` knows `out:` and nothing else — everything remaining is
    # the TARGET's own vocabulary, so a projector can grow an option
    # without this method learning about it.
    it "passes unknown keywords through to the projector untouched" do
      projected = domain.project(Hecksagain::Projections::OIDC, audience: "https://api.example.com")

      expect(projected["audience"]).to eq("https://api.example.com")
    end
  end

  describe "out:" do
    it "is pure without it — the artifact comes back and nothing is written" do
      Dir.mktmpdir do |dir|
        domain.project(Hecksagain::Projections::OIDC)

        expect(Dir.children(dir)).to be_empty
      end
    end

    it "writes JSON and answers with the path when given one" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "oidc.json")

        expect(domain.project(Hecksagain::Projections::OIDC, out: path)).to eq(path)
        expect(JSON.parse(File.read(path))).to eq(JSON.parse(JSON.generate(domain.project(Hecksagain::Projections::OIDC))))
      end
    end

    it "writes a String artifact verbatim rather than as JSON" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "raw.txt")
        Hecksagain::Projector.register(:stub_text, Class.new {
          def self.call(bluebook:, options: {}) = "just text, not #{bluebook.name.inspect} as JSON"
        })

        domain.project(:stub_text, out: path)

        expect(File.read(path)).to eq('just text, not "Pizzas" as JSON')
      ensure
        Hecksagain::Projector.registry.delete(:stub_text)
      end
    end
  end

  # The reason `to_ir` is deliberately absent: one verb, and the
  # canonical serialized form is what `project(IR)` already answers.
  it "exposes no second way to reach the IR" do
    expect(domain).not_to respond_to(:to_ir)
  end

  # The registry-first path stays available and is what anything
  # order-sensitive should use — Facade::Namespace.install warns and
  # KEEPS a pre-existing constant rather than clobbering it, so a domain
  # named `Set` never gets a constant at all, and a prior boot's module
  # can linger on Object.
  it "agrees with calling the registry directly, without any constant" do
    expect(Hecksagain::Projector.call(:oidc, bluebook: bluebook))
      .to eq(domain.project(Hecksagain::Projections::OIDC))
  end
end
