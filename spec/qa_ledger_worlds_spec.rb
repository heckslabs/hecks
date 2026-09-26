require "spec_helper"

# The real QA ledger boots against its own committed world files. The other
# ledger specs write a disposable fixture directory, so a world file missing
# from qa/bluebook itself only shows up when bin/run qa/bluebook refuses to
# boot. Static on purpose: no database is opened.
RSpec.describe "the QA ledger's world files" do
  LEDGER_DIR = File.join(InMemoryDomain::ROOT, "qa/bluebook").freeze

  def self.postgres_era_domains
    Dir[File.join(LEDGER_DIR, "*.hecksagon")].flat_map do |path|
      text = File.read(path)
      next [] unless text.include?('persisted_by("PostgresEra")')

      text.scan(/Hecks\.hecksagon\s+"([^"]+)"/).flatten
    end
  end

  def world_text_for(domain)
    Dir[File.join(LEDGER_DIR, "*.world")].map { |path| File.read(path) }
                                         .find { |text| text.include?(%(Hecks.world "#{domain}")) }
  end

  it "finds the domains that bind PostgresEra" do
    expect(self.class.postgres_era_domains).to include("QualityControl", "Governance")
  end

  postgres_era_domains.each do |domain|
    it "declares a database for #{domain} in a world of the same name" do
      world = world_text_for(domain)

      expect(world).not_to be_nil
      expect(world).to match(/database\s+"[^"]+"/)
    end
  end
end
