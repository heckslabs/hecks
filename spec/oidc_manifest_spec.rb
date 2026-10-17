require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require "hecks/tools/oidc_manifests"

# Anti-drift gate: each checked-in manifest must equal a fresh projection of its chapter. A domain
# of one chapter keeps `oidc.json`; a directory of several chapters holds `<chapter>.oidc.json`
# for each, so no chapter's manifest stands for another's. Directories are found by the same glob
# `hecks deploy oidc_manifest.project_oidc` uses.
RSpec.describe "committed OIDC manifests (hecks deploy oidc_manifest.project_oidc)" do
  ROOT = InMemoryDomain::ROOT

  def self.relative(path) = path.delete_prefix("#{ROOT}/")

  def self.excluded?(path) = relative(path).match?(%r{\A(rust|deploy|tmp|coverage)/})

  OIDC_MANIFESTS = Dir.glob(File.join(ROOT, "**/*oidc.json")).reject { |path| excluded?(path) }.freeze
  OIDC_DIRECTORIES = OIDC_MANIFESTS.map { |path| File.dirname(path) }.uniq.freeze

  def relative(path) = self.class.relative(path)

  def tool = Hecks::Tools::OidcManifests

  def booted(directory) = Hecks.boot(directory, install_driving: false).registry

  # What `hecks deploy oidc_manifest.project_oidc` would write for the chapter of the file at `path`.
  def projection_for(path)
    registry = booted(File.dirname(path))
    names = tool.chapters_of(registry, File.dirname(path))
    name = names.find { |held| tool.file_for(names, held) == File.basename(path) }
    Hecks::Projections::OIDC.render(Hecks::Projector.call(:oidc, bluebook: registry.bluebook(name)))
  end

  def drift_message(path)
    "#{relative(path)} has drifted from its chapter — run hecks deploy oidc_manifest.project_oidc"
  end

  it "found at least one committed manifest to check — this spec's own discovery is not stale" do
    expect(OIDC_MANIFESTS).not_to be_empty,
                                  "no oidc.json found under #{ROOT} — hecks deploy oidc_manifest.project_oidc has never " \
                                  "been run, or every manifest was deleted without updating this spec's exclusion list"
  end

  it "names a manifest oidc.json for a domain of one chapter, and <chapter>.oidc.json otherwise" do
    expect([tool.file_for(%w[Banking], "Banking"), tool.file_for(%w[Compliance ConsoleSettings], "ConsoleSettings")])
      .to eq(["oidc.json", "console_settings.oidc.json"])
  end

  OIDC_MANIFESTS.each do |path|
    # `:io` on every example: a domain that commits a manifest may be PostgresEra-bound.
    it "#{relative(path)} is exactly what hecks deploy oidc_manifest.project_oidc would regenerate right now", :io do
      expect(projection_for(path)).to eq(File.read(path)), drift_message(path)
    end
  end

  OIDC_DIRECTORIES.each do |directory|
    it "#{relative(directory)} holds one manifest for each chapter it has, and no other", :io do
      names = tool.chapters_of(booted(directory), directory)

      expect(Dir.children(directory).grep(/oidc\.json\z/).sort).to eq(names.map { |name| tool.file_for(names, name) }.sort)
    end
  end
end
