require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/agents/adapters/submitted_paths"

# The scope a submission review counts evidence against, read from a scratch checkout under a
# temporary directory and a stand-in git, with the ChangeReview rows of the Agents bluebook.
RSpec.describe Hecks::Adapters::SubmittedPaths, "#read_scope" do
  around do |example|
    Dir.mktmpdir("review-scope") do |dir|
      @root = dir
      example.run
    end
  end

  def status = instance_double(Process::Status, success?: true)

  def place(file)
    FileUtils.mkdir_p(File.dirname(File.join(@root, file)))
    File.write(File.join(@root, file), "")
  end

  def scope(listing)
    git = ->(_argv) { [listing, "", status] }
    described_class.new(git: git).read_scope(submission: "abc1234", checkout: @root).transform_values { |field| field[:value] }
  end

  before { %w[lib/hecks/agents/agents.bluebook lib/hecks/tickets/bluebook/tickets.bluebook].each { |file| place(file) } }

  it "answers a full commit's touched domains and the domains of its changed bluebooks" do
    listing = "M\tlib/hecks/agents/adapters/run_records.rb\nM\tlib/hecks/tickets/bluebook/tickets.bluebook\n"
    expect(scope(listing)).to eq(tier: "full", domains: "|lib/hecks/agents|lib/hecks/tickets|",
                                 bluebooks: "|lib/hecks/tickets|")
  end

  it "answers a docs-only commit as verify_only touching no domain" do
    expect(scope("M\tdocs/a.md\n")).to eq(tier: "verify_only", domains: "||", bluebooks: "||")
  end
end
