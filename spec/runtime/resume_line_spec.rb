require "spec_helper"
require "hecks/adapters/driving/cli_runner/resume_line"

# The line a resume dispatches, against stand-in declarations: which saved arguments a stage's
# command is handed, how each is written, and when the run is named as the receiver.
RSpec.describe Hecks::Adapters::Driving::CliRunner::ResumeLine do
  let(:attribute) { Struct.new(:name) }
  let(:command)   { Struct.new(:hecks_name, :attributes, :creates?) }
  let(:aggregate) { Struct.new(:hecks_name, :commands) }

  def declares(name, takes, creates:)
    command.new(name, takes.map { |word| attribute.new(word) }, creates)
  end

  def bluebook(*commands) = Struct.new(:aggregates).new([aggregate.new("Landing", commands)])

  def words(verb, saved, *commands) = described_class.new(bluebook(*commands), verb).words("r1", saved)

  it "hands a command only the saved arguments it declares" do
    land = declares("Land", %i[run branch], creates: true)
    expect(words("Landing.Land", { run: "r1", branch: "feature", paths: "lib" }, land))
      .to eq(["Landing.Land!", "run=r1", "branch=feature"])
  end

  it "names the run as the receiver of a command on a record already made" do
    retire = declares("Retire", [], creates: false)
    expect(words("Landing.Retire", { run: "r1", branch: "feature" }, retire)).to eq(["Landing.Retire!", "to=r1"])
  end

  it "writes a saved value held as a one-field record as its bare value" do
    land = declares("Land", %i[run confirm], creates: true)
    expect(words("Landing.Land", { run: { value: "r1" }, confirm: { "value" => true } }, land))
      .to eq(["Landing.Land!", "run=r1", "confirm=true"])
  end

  it "leaves out a saved argument that holds nothing" do
    land = declares("Land", %i[run confirm], creates: true)
    expect(words("Landing.Land", { run: "r1", confirm: nil }, land)).to eq(["Landing.Land!", "run=r1"])
  end

  it "hands everything to a command no aggregate declares" do
    expect(words("Landing.Gone", { run: "r1", branch: "feature" })).to eq(["Landing.Gone!", "run=r1", "branch=feature"])
  end
end
