require "spec_helper"
require "fileutils"
require "tmpdir"
require_relative "../../../lib/hecks/hecks/adapters/rehearsal"

# Which environment overlay a rehearsal loads, and how that is named in the report.
RSpec.describe Hecks::Adapters::Rehearsal::Environment do
  let(:directory) { Dir.mktmpdir("hecks-rehearsal-environment") }

  after do
    ENV.delete("HECKS_PROJECT_ENVIRONMENT")
    FileUtils.remove_entry(directory)
  end

  def overlay(name)
    FileUtils.mkdir_p(File.join(directory, "environments"))
    FileUtils.touch(File.join(directory, "environments", "#{name}.hecksagon"))
  end

  it "takes the name the world declares over everything else", :aggregate_failures do
    ENV["HECKS_PROJECT_ENVIRONMENT"] = "memory"
    overlay("production")
    chosen = described_class.resolve("staging", directory)

    expect([chosen.name, chosen.source]).to eq(%w[staging world])
  end

  it "takes HECKS_PROJECT_ENVIRONMENT before the default", :aggregate_failures do
    ENV["HECKS_PROJECT_ENVIRONMENT"] = "memory"
    overlay("production")

    expect(described_class.resolve(nil, directory).source).to eq("HECKS_PROJECT_ENVIRONMENT")
  end

  it "defaults to production when its overlay exists, as the host build does", :aggregate_failures do
    overlay("production")
    chosen = described_class.resolve(nil, directory)

    expect([chosen.name, chosen.source]).to eq(%w[production default])
  end

  it "loads none when the domain has no production overlay", :aggregate_failures do
    chosen = described_class.resolve(nil, directory)

    expect(chosen.overlay).to be_nil
    expect(chosen.facts).to eq(name: "", source: "none", file: "")
  end

  it "says when the file it was to look in is not there" do
    expect(described_class.resolve("staging", directory).to_s).to include("NOT FOUND")
  end
end
