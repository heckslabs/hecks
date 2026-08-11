
require "spec_helper"
require_relative "support/doctest"

# Every guide's examples RUN — see spec/support/doctest.rb for the fence
# and marker vocabulary. One example per guide; a guide with no
# executable blocks passes trivially; a guide whose first line carries
# the postgres pragma skips cleanly when no local Postgres answers.
RSpec.describe "the guides" do
  GUIDES = (Dir.glob(File.join(InMemoryDomain::ROOT, "docs/guides/*.md")).sort -
            [File.join(InMemoryDomain::ROOT, "docs/guides/AUTHORING.md"),
             File.join(InMemoryDomain::ROOT, "docs/guides/index.md")]) +
           [File.join(InMemoryDomain::ROOT, "README.md")]

  # Facade constants install onto Object and are never uninstalled, so
  # two guides declaring the same chapter would silently rebind to
  # whichever booted last — under random spec order, a coin flip. Names
  # are claimed once, across the whole set, before anything boots.
  it "gives every guide its own domain names" do
    claimed = {}
    GUIDES.each do |path|
      Doctest.declared_domains(Doctest.parse(path)).each do |domain|
        owner = claimed[domain]
        expect(owner).to be_nil,
                         "#{File.basename(path)} declares #{domain.inspect}, already declared " \
                         "by #{owner && File.basename(owner)} — guides own their names alone"
        claimed[domain] = path
      end
    end
  end

  GUIDES.each do |path|
    # Parsed here, at collection-build time, not inside the `it` — a
    # guide's postgres pragma has to be known BEFORE the example runs,
    # so it can carry as `io: true` and get excluded locally by default
    # the same as every other real-Postgres spec.
    guide = Doctest.parse(path)

    it "#{File.basename(path)} says nothing its examples cannot back", io: guide.postgres do
      skip "no reachable Postgres — start one to run this guide" if guide.postgres && !Doctest::POSTGRES_AVAILABLE
      if File.basename(path) == "schema-evolution.md" && !Doctest::PIZZAS_HISTORY_AVAILABLE
        skip "documents examples/pizzas' own real era-1→2 migration — only present on a machine " \
             "that actually lived through it, not a fresh hecks_pizzas database"
      end

      expect(Doctest.run(path)).to be(true)
    end
  end
end
