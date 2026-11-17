require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/last_verified"

# The last-verified-main marker: one JSON file in the git directory, written whole, read tolerantly.
RSpec.describe Hecks::Adapters::MainIntegration::LastVerified do
  let(:dir) { Dir.mktmpdir("hecks-last-verified") }

  after { FileUtils.remove_entry(dir) }

  it "reads back the commit and the time it wrote", :aggregate_failures do
    described_class.write(dir, "a" * 40, at: Time.utc(2026, 11, 16, 9, 30))
    expect(described_class.read(dir)).to include("sha" => "a" * 40, "at" => "2026-11-16T09:30:00Z")
  end

  it "keeps only the marker in the directory" do
    described_class.write(dir, "a" * 40)
    expect(Dir.children(dir)).to eq([described_class::FILE])
  end

  it "reads nothing before a verification wrote one" do
    expect(described_class.read(dir)).to be_nil
  end

  it "reads nothing from a marker that is not JSON" do
    File.write(File.join(dir, described_class::FILE), "{")
    expect(described_class.read(dir)).to be_nil
  end
end
