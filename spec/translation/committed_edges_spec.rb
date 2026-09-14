require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# EVERY COMMITTED TRANSLATION EDGE, CHECKED WITHOUT A DATABASE.
#
# A domain's `bluebook/translations/*.bluebook` edges are the record of
# how its storage shape moved from era to era. Nothing else gated reads
# the committed ones: Fuzzing::IsolatedBoot strips `translations/` before
# every sweep, and the Postgres specs that apply an edge build their own
# (only examples/directory's is read off disk, and only under `io: true`).
# So an edge could fail to load, skip an era, or fall behind its bluebook
# and every suite would stay green.
#
# Discovered, not listed — every sweepable domain with a
# `bluebook/translations/` directory. For each: every edge loads through
# the translation judge and names this chapter; the files run 2, 3, 4, ...
# with no hole; each edge starts where the previous one ended and is named
# for the era it lands on; and the newest lands on the storage shape the
# chapter declares TODAY, so a shape change committed without its edge
# fails here.
RSpec.describe "the committed translation edges" do
  def self.domains_with_edges
    Hecks::Corpus.sweepable_domains.select { |domain| File.directory?(File.join(domain, "bluebook", "translations")) }
  end

  def chapter_in(bluebook_dir)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(bluebook_dir)
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
