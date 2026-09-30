require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# Anti-drift gate: each checked-in `oidc.json` must equal a fresh projection of its bluebook.
# Manifests are found by the same domain glob `hecks deploy project_oidc` uses.
RSpec.describe "committed OIDC manifests (hecks deploy project_oidc)" do
  ROOT = InMemoryDomain::ROOT

  def self.excluded?(path)
    path.match?(%r{\A(rust|deploy|tmp|coverage)/})
  end

  manifests = Dir.glob(File.join(ROOT, "**/oidc.json")).reject do |path|
    excluded?(path.delete_prefix("#{ROOT}/"))
  end

  it "found at least one committed manifest to check — this spec's own discovery is not stale" do
    expect(manifests).not_to be_empty,
                             "no oidc.json found under #{ROOT} — hecks deploy project_oidc has never been run, or every " \
                             "manifest was deleted without updating this spec's own exclusion list"
  end

  manifests.each do |path|
    relative = path.delete_prefix("#{ROOT}/")
    domain   = File.dirname(relative)

    # `:io` on every example: a domain that commits an oidc.json may be PostgresEra-bound.
    it "#{relative} is exactly what hecks deploy project_oidc would regenerate right now", :io do
      runtime  = Hecks.boot(File.join(ROOT, domain), install_doors: false)
      name     = runtime.registry.bluebooks.keys.first
      bluebook = runtime.registry.bluebook(name)

      projected = "#{JSON.pretty_generate(Hecks::Projector.call(:oidc, bluebook: bluebook))}\n"
      committed = File.read(path)

      expect(projected).to eq(committed), "#{relative} has drifted from #{domain}'s bluebook — run hecks deploy project_oidc"
    end
  end
end
