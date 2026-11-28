require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/launcher"

# A launcher that boots a domain from another repository names itself, so the kept-aggregate
# refusal points at it and at its own repository.
RSpec.describe Hecks::Adapters::Driving::Launcher do
  around do |example|
    Dir.mktmpdir("launcher") do |yard|
      @yard = yard
      FileUtils.mkdir_p([File.join(yard, ".git"), File.join(yard, "exe")])
      example.run
    end
  end

  def env = { "HECKS_LAUNCHER" => File.join(@yard, "exe/switchyard") }

  it "reads the named launcher's path and the root of its repository", :aggregate_failures do
    expect(described_class.path(env)).to eq(File.join(@yard, "exe/switchyard"))
    expect(File.realpath(described_class.root(env))).to eq(File.realpath(@yard))
  end

  it "tells the reader to run the named launcher" do
    expect(described_class.command(env)).to eq(File.join(@yard, "exe/switchyard"))
  end

  it "names no launcher, and so exe/hecks, when none is set", :aggregate_failures do
    expect(described_class.root({})).to be_nil
    expect(described_class.command({})).to eq("exe/hecks")
  end
end
