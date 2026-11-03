require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "hecks/hecks/adapters/git_rehearsal"

# The flake counts kept beside the rehearsal record in a scratch repository's common git directory.
RSpec.describe Hecks::Adapters::GitRehearsal::Record, "#count_flakes" do
  let(:root) { Dir.mktmpdir("hecks-flake-record") }
  let(:record) { described_class.new(Hecks::Adapters::Git.new, root) }
  let(:file) { File.join(root, ".git", described_class::FLAKES) }

  def fresh_record = described_class.new(Hecks::Adapters::Git.new, root)

  before { Open3.capture2e("git", "init", "-q", root) }

  after { FileUtils.remove_entry(root) }

  it "starts a file at one" do
    expect(record.count_flakes(["spec/a_spec.rb"])).to eq("spec/a_spec.rb" => 1)
  end

  it "adds one for each rehearsal", :aggregate_failures do
    3.times { record.count_flakes(["spec/a_spec.rb"]) }
    expect(record.count_flakes(%w[spec/a_spec.rb spec/b_spec.rb])).to eq("spec/a_spec.rb" => 4, "spec/b_spec.rb" => 1)
    expect(JSON.parse(File.read(file))).to eq("spec/a_spec.rb" => 4, "spec/b_spec.rb" => 1)
  end

  it "loses no count when rehearsals count at once", :aggregate_failures do
    Array.new(8) { Thread.new { 5.times { fresh_record.count_flakes(["spec/a_spec.rb"]) } } }.each(&:join)
    expect(record.flake_counts).to eq("spec/a_spec.rb" => 40)
    expect(Dir.children(File.join(root, ".git")).grep(/\.tmp\z/)).to be_empty
  end

  it "writes nothing when no file was flaky" do
    record.count_flakes([])
    expect(File.exist?(file)).to be(false)
  end

  it "starts over from a count file it cannot read", :aggregate_failures do
    File.write(file, "not json")
    expect(record.flake_counts).to eq({})
    expect(record.count_flakes(["spec/a_spec.rb"])).to eq("spec/a_spec.rb" => 1)
  end
end
