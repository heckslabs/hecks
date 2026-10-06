require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# Anti-drift gate: each checked-in `oidc.json` must equal a fresh projection of its bluebook.
# Manifests are found by the same domain glob `hecks deploy project_oidc` uses.
RSpec.describe "committed OIDC manifests (hecks deploy project_oidc)" do
  ROOT = InMemoryDomain::ROOT

  def self.relative(path) = path.delete_prefix("#{ROOT}/")

  def self.excluded?(path) = relative(path).match?(%r{\A(rust|deploy|tmp|coverage)/})

  OIDC_MANIFESTS = Dir.glob(File.join(ROOT, "**/oidc.json")).reject { |path| excluded?(path) }.freeze

  def relative(path) = self.class.relative(path)

  # What `hecks deploy project_oidc` would write for the domain beside the manifest at `path`.
  def projection_for(path)
    runtime = Hecks.boot(File.join(ROOT, File.dirname(relative(path))), install_doors: false)
    bluebook = runtime.registry.bluebook(runtime.registry.bluebooks.keys.first)
    "#{JSON.pretty_generate(Hecks::Projector.call(:oidc, bluebook: bluebook))}\n"
  end

  def drift_message(path)
    "#{relative(path)} has drifted from #{File.dirname(relative(path))}'s bluebook — run hecks deploy project_oidc"
  end

  it "found at least one committed manifest to check — this spec's own discovery is not stale" do
    expect(OIDC_MANIFESTS).not_to be_empty,
                                  "no oidc.json found under #{ROOT} — hecks deploy project_oidc has never been run, or every " \
                                  "manifest was deleted without updating this spec's own exclusion list"
  end

  OIDC_MANIFESTS.each do |path|
    # `:io` on every example: a domain that commits an oidc.json may be PostgresEra-bound.
    it "#{relative(path)} is exactly what hecks deploy project_oidc would regenerate right now", :io do
      expect(projection_for(path)).to eq(File.read(path)), drift_message(path)
    end
  end
end
