require "spec_helper"

# `hecks search <word>` (ADR 0163, step 20) answers from the real Hecks domain's projection:
# the commands and queries a word appears in, each as the call to type.
RSpec.describe Hecks::Adapters::Driving::CliRunner do
  let(:runtime) { Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__), environment: nil) }

  def run(*argv) = described_class.usage(runtime: runtime, argv: argv, program: "hecks")
  def text(*argv) = run(*argv).first
  def status(*argv) = run(*argv).last

  it "lists a command whose call holds the word" do
    expect(text("search", "ship")).to include("Shipment.ship!")
  end

  it "lists a command found only by its description" do
    expect(text("search", "membership")).to include("Operation.bootstrap_admin!")
  end

  it "answers a word that matches nothing with status 1" do
    expect(status("search", "nothing-here")).to eq(1)
  end

  it "names the missing word in the no-match line" do
    expect(text("search", "nothing-here")).to eq("no command or query matches nothing-here")
  end

  it "answers a search with no word with the usage line and status 1" do
    expect(run("search")).to eq(["usage: hecks search <word> [--all]", 1])
  end

  it "lists more hits with --all than without" do
    expect(text("search", "accept", "--all").lines.size).to be > text("search", "accept").lines.size
  end

  it "finds an internal command with --all" do
    expect(text("search", "accept", "--all")).to include("accept!")
  end
end
