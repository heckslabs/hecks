require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/agents/adapters/submitted_paths"

# The domains a submitted commit touches are the `DomainPath` rows of the Agents bluebook's
# ChangeReview, read against a scratch checkout under a temporary directory and a stand-in git.
RSpec.describe Hecks::Adapters::SubmittedPaths, "#domains" do
  around do |example|
    Dir.mktmpdir("review-domains") do |dir|
      @root = dir
      example.run
    end
  end

  def status = instance_double(Process::Status, success?: true)

  FILES = %w[lib/hecks/agents/agents.bluebook lib/hecks/tickets/bluebook/tickets.bluebook
             lib/hecks/triage/triage.behaviors lib/hecks/triage/triage.bluebook].freeze

  def place(file)
    FileUtils.mkdir_p(File.dirname(File.join(@root, file)))
    File.write(File.join(@root, file), "")
  end

  def domains(listing)
    git = ->(_argv) { [listing, "", status] }
    described_class.new(git: git).domains(review: "abc1234", checkout: @root)[:text].lines.map(&:strip)
  end

  before { FILES.each { |file| place(file) } }

  it "maps an adapter path to the domain whose bluebook is above it" do
    expect(domains("M\tlib/hecks/agents/adapters/submitted_paths.rb\n")).to eq(["lib/hecks/agents"])
  end

  it "maps a bluebook in a bluebook folder to the folder's parent" do
    expect(domains("M\tlib/hecks/tickets/bluebook/tickets.bluebook\n")).to eq(["lib/hecks/tickets"])
  end

  it "maps the Rust host to every domain that has a behaviors file" do
    expect(domains("M\trust/host/src/main.rs\n")).to eq(["lib/hecks/triage"])
  end

  it "maps a path no domain owns under lib to every domain with behaviors" do
    expect(domains("M\tlib/hecks/naming.rb\n")).to eq(["lib/hecks/triage"])
  end

  it "maps a spec or a doc to no domain" do
    expect(domains("M\tspec/a_spec.rb\nM\tdocs/a.md\n")).to eq([])
  end
end
