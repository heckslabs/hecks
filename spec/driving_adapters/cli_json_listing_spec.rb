require "spec_helper"
require "json"

# `hecks --json` and `hecks <module> --json` (ADR 0163, plan step 9) print the listing's entries
# as JSON, from the same projection the help prints.
RSpec.describe Hecks::Adapters::Driving::CliRunner do
  let(:runtime) { Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__), environment: nil) }

  def run(*argv) = described_class.usage(runtime: runtime, argv: argv, program: "hecks")
  def entries(*argv) = JSON.parse(run(*argv).first)
  def calls(*argv) = entries(*argv).map { |entry| entry["call"] }

  it "prints the entries as a JSON array that parses" do
    expect(entries("--json")).to be_an(Array)
  end

  it "lists every command the text listing names" do
    expect(calls("--json")).to all(satisfy { |call| run.first.include?(call.split(".").last) })
  end

  it "lists only one module's entries when a module is named" do
    expect(entries("deliver", "--json").map { |entry| entry["module"] }.uniq).to eq(["deliver"])
  end

  it "marks the everyday calls" do
    expect(entries("deliver", "--json").select { |entry| entry["everyday"] }.map { |e| e["call"] })
      .to include("Shipment.ship!")
  end

  it "answers an unknown module word with the usage line and the usage status" do
    expect(run("nosuch", "--json")).to eq(["usage: hecks [<module>] --json", 2])
  end
end
