require "spec_helper"
require_relative "support/cli_help_mask"

# The masked help keeps the names, headings and layout and drops what a bluebook says, so two
# branches that touch commands each leave the golden as it was, or change only their own lines.
RSpec.describe CliHelpMask do
  def help(goal: "Generate a domain's Rust source", note: "One build of a domain.", extra: nil)
    <<~TEXT
      build — Compile and regenerate.

        hecks <Aggregate.command>! [name=value …]    do something

      commands:
        Build:
          #{note}
          project_rust!  #{goal}
          #{extra}build_wasm!    Compile a domain to a WASI module (also: wasm!)
        Dial:
          turn!  Set one turnable setting

        hecks --all                  also list the internal commands and queries
    TEXT
  end

  it "masks a reworded command description to the same help" do
    expect(described_class.mask(help(goal: "Write the Rust source of a domain"))).to eq(described_class.mask(help))
  end

  it "masks a reworded aggregate note to the same help" do
    expect(described_class.mask(help(note: "A build, said otherwise."))).to eq(described_class.mask(help))
  end

  it "keeps the first row of an aggregate with no note as its name" do
    expect(described_class.mask(help).lines.map(&:chomp)).to include("  Dial:", "    turn!")
  end

  it "keeps the usage and footer lines, which are the launcher's own text", :aggregate_failures do
    masked = described_class.mask(help)
    expect(masked).to include("  hecks <Aggregate.command>! [name=value …]    do something")
    expect(masked).to include("  hecks --all                  also list the internal commands and queries")
  end

  it "masks the module's vision and keeps its name" do
    expect(described_class.mask(help).lines.first).to eq("build —\n")
  end

  it "adds one line for a longer name, re-padding no row beside it" do
    longer = help.sub("    project_rust!", "    project_rust_and_more!  New\n    project_rust!")
    expect(described_class.mask(longer).lines - described_class.mask(help).lines).to eq(["    project_rust_and_more!\n"])
  end

  it "reads each row's description with its alias note left out" do
    rows = described_class.rows(help).map { |row| [row[:group], row[:name], row[:text]] }
    expect(rows).to include(["Build", "build_wasm!", "Compile a domain to a WASI module"])
  end

  it "reads each aggregate's note and none for an aggregate without one" do
    expect(described_class.notes(help)).to eq([{ group: "Build", text: "One build of a domain." }])
  end
end
