require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/release/bump"

# The bump a release cut writes: the next version in every file that names the version.
RSpec.describe Hecks::Release::Bump do
  let(:root) { Dir.mktmpdir("hecks-bump-spec") }

  before do
    {
      "lib/hecks/version.rb"               => %(module Hecks\n  VERSION = "7.1.0".freeze\nend\n),
      "rust/host/HECKS_RELEASE"            => "7.1.0\n",
      "packages/hecks-client/package.json" => JSON.pretty_generate("version" => "7.1.0"),
      "README.md"                          => "Current release: `7.1.0`.\n\nCurrent release: `7.1.0`.\n",
      "CHANGELOG.md"                       => "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- a thing\n"
    }.each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
    end
  end

  after { FileUtils.rm_rf(root) }

  it "names the next version of each level", :aggregate_failures do
    expect(described_class.next_version("7.1.4", "patch")).to eq("7.1.5")
    expect(described_class.next_version("7.1.4", "minor")).to eq("7.2.0")
    expect(described_class.next_version("7.1.4", "major")).to eq("8.0.0")
  end

  it "refuses a level it does not know" do
    expect { described_class.next_version("7.1.0", "huge") }.to raise_error(ArgumentError, /major, minor or patch/)
  end

  it "writes the version into every file", :aggregate_failures do
    described_class.apply(root, level: "minor", date: "2026-11-23")

    expect(File.read(File.join(root, "lib/hecks/version.rb"))).to include('VERSION = "7.2.0"')
    expect(File.read(File.join(root, "rust/host/HECKS_RELEASE"))).to eq("7.2.0\n")
    expect(JSON.parse(File.read(File.join(root, "packages/hecks-client/package.json")))["version"]).to eq("7.2.0")
    expect(File.read(File.join(root, "README.md")).scan("Current release: `7.2.0`").size).to eq(2)
  end

  it "puts the unreleased entries under a dated heading" do
    described_class.apply(root, level: "patch", date: "2026-11-23")

    expect(File.read(File.join(root, "CHANGELOG.md"))).to include("## [Unreleased]\n\n## [7.1.1] - 2026-11-23\n\n### Added")
  end
end
