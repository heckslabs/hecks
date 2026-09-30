require "spec_helper"
require "hecks/ports/persistence/plugins/era"

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
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
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

  it "finds the committed edges (the discovery itself is not silently empty)" do
    expect(self.class.domains_with_edges.map { |domain| domain.delete_prefix("#{InMemoryDomain::ROOT}/") })
      .to include("examples/pizzas", "qa", "examples/directory")
  end

  domains_with_edges.each do |domain|
    it "#{domain.delete_prefix("#{InMemoryDomain::ROOT}/")}: its edges load, chain era to era, " \
       "and end at the shape its bluebook declares today" do
      bluebook_dir = File.join(domain, "bluebook")
      chapter = chapter_in(bluebook_dir)
      label = Hecks::Runtime::StorageShape.mint_label(chapter)
      files = Dir[File.join(bluebook_dir, "translations", "*.bluebook")].sort_by { |file| File.basename(file).to_i }

      expect(files.map { |file| File.basename(file).to_i }).to eq((2..(files.size + 1)).to_a)

      previous = nil
      files.each do |file|
        edge = edge_in(file)
        expect(edge.domain).to eq(chapter.name)
        expect(File.basename(file, ".bluebook")).to eq("#{File.basename(file).to_i}-#{edge.to}")
        expect(edge.from).to eq(previous.to), "#{File.basename(file)} starts at #{edge.from}, not #{previous.to}" if previous
        previous = edge
      end

      expect(previous.to).to eq(label),
                             "the newest edge lands on #{previous.to}, but #{chapter.name}'s bluebook now declares " \
                             "#{label} — commit the translation edge for that change"
    end
  end
end
