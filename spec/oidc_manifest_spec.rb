require "spec_helper"

# THE ANTI-DRIFT GATE for every checked-in `oidc.json` — the same shape
# spec/vocabulary_table_spec.rb and spec/parser_table_spec.rb already use
# for their own generated artifacts: regenerate in memory from the
# domain's own bluebook and refuse a diff, so a manifest that stopped
# matching its source fails the ordinary suite rather than waiting for
# someone to notice a stale client scope list in production.
#
# Discovered dynamically, not a hardcoded list — the same domain-glob
# `bin/project_oidc` itself uses, so a new domain that runs the driver and
# commits its own oidc.json is covered here for free, and a domain whose
# manifest gets deleted simply drops out rather than leaving a stale
# expectation behind.
RSpec.describe "committed OIDC manifests (bin/project_oidc)" do
  ROOT = InMemoryDomain::ROOT

  def self.excluded?(path)
    path.match?(%r{\A(rust|deploy|tmp|coverage)/})
  end

  manifests = Dir.glob(File.join(ROOT, "**/oidc.json")).reject do |path|
    excluded?(path.delete_prefix("#{ROOT}/"))
  end

  it "found at least one committed manifest to check — this spec's own discovery is not stale" do
    expect(manifests).not_to be_empty,
                             "no oidc.json found under #{ROOT} — bin/project_oidc has never been run, or every " \
                             "manifest was deleted without updating this spec's own exclusion list"
  end

  manifests.each do |path|
    relative = path.delete_prefix("#{ROOT}/")
    domain   = File.dirname(relative)

    it "#{relative} is exactly what bin/project_oidc would regenerate right now" do
      runtime  = Hecks.boot(File.join(ROOT, domain), install_facade: false)
      name     = runtime.registry.bluebooks.keys.first
      bluebook = runtime.registry.bluebook(name)

      projected = "#{JSON.pretty_generate(Hecks::Projector.call(:oidc, bluebook: bluebook))}\n"
      committed = File.read(path)

      expect(projected).to eq(committed), "#{relative} has drifted from #{domain}'s bluebook — run bin/project_oidc"
    end
  end
end
