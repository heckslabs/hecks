require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/memory_ports"

# Checks every committed bluebook/translations edge without a database: each loads, the chain runs
# era to era, and the newest lands on the shape the bluebook declares today.
# Nothing else reads them: Fuzzing::IsolatedBoot strips translations/ before every sweep.
RSpec.describe "the committed translation edges" do
  # The QA ledger's chapter ships in lib/, so its directory holds no bluebook of its own to be
  # swept; its edges stay beside the wiring and the world that name its database.
  def self.domains_with_edges
    ledgers = Hecks::Corpus::ROTATION_LEDGER.values.map { |path| File.join(InMemoryDomain::ROOT, File.dirname(path)) }
    (Hecks::Corpus.sweepable_domains | ledgers)
      .select { |domain| File.directory?(File.join(domain, "bluebook", "translations")) }
  end

  def chapter_in(bluebook_dir)
    files = Hecks::Corpus.bluebook_files(bluebook_dir)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      load_bluebook_files(files)
    end
    registry.bluebooks.values.first
  end

  def edge_in(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(file) }
    expect(registry.translations.size).to eq(1), "#{file} declares #{registry.translations.size} translations, not one"
    registry.translations.first
  end

  def edge_files(bluebook_dir)
    Dir[File.join(bluebook_dir, "translations", "*.bluebook")].sort_by { |file| File.basename(file).to_i }
  end

  # Expects every edge to name the chapter and start where the one before it ended, and the newest
  # to land on the storage shape the chapter declares today.
  def expect_chain(chapter, files)
    edges = files.map { |file| edge_in(file) }
    files.zip(edges).each { |file, edge| expect_edge(chapter, file, edge) }
    files.zip(edges).each_cons(2) { |(_, before), (file, after)| expect_link(file, before, after) }
    expect_newest_current(chapter, edges.last)
  end

  def expect_edge(chapter, file, edge)
    expect(edge.domain).to eq(chapter.name)
    expect(File.basename(file, ".bluebook")).to eq("#{File.basename(file).to_i}-#{edge.to}")
  end

  def expect_link(file, before, after)
    expect(after.from).to eq(before.to), "#{File.basename(file)} starts at #{after.from}, not #{before.to}"
  end

  def expect_newest_current(chapter, newest)
    label = Hecks::Runtime::StorageShape.mint_label(chapter)
    expect(newest.to).to eq(label),
                         "the newest edge lands on #{newest.to}, but #{chapter.name}'s bluebook now declares " \
                         "#{label} — commit the translation edge for that change"
  end

  it "finds the committed edges (the discovery itself is not silently empty)" do
    expect(self.class.domains_with_edges.map { |domain| domain.delete_prefix("#{InMemoryDomain::ROOT}/") })
      .to include("examples/pizzas", "qa", "examples/directory")
  end

  domains_with_edges.each do |domain|
    it "#{domain.delete_prefix("#{InMemoryDomain::ROOT}/")}: its edges load, chain era to era, " \
       "and end at the shape its bluebook declares today", :aggregate_failures do
      bluebook_dir = File.join(domain, "bluebook")
      chapter = chapter_in(bluebook_dir)
      files = edge_files(bluebook_dir)

      expect(files.map { |file| File.basename(file).to_i }).to eq((2..(files.size + 1)).to_a)
      expect_chain(chapter, files)
    end
  end
end
