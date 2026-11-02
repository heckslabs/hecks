require "spec_helper"
require "open3"

# `hecks completion <shell>` (ADR 0163, plan step 7) writes the completion script for bash, zsh
# or fish, from the same listing the help prints, so a new command or module reaches it without
# a second list.
RSpec.describe Hecks::Adapters::Driving::CliRunner do
  let(:runtime) { Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__), environment: nil) }

  def run(*argv) = described_class.usage(runtime: runtime, argv: argv, program: "hecks")
  def text(*argv) = run(*argv).first
  def status(*argv) = run(*argv).last

  it "completes the module names and the everyday names in bash" do
    expect(text("completion", "bash")).to include("operate", "Operation.run!")
  end

  it "completes a command's full call in zsh" do
    expect(text("completion", "zsh")).to include("'Shipment.ship!'")
  end

  it "writes a fish script that offers the everyday names" do
    expect(text("completion", "fish")).to include("Shipment.ship!")
  end

  it "writes a bash script bash accepts" do
    expect(Open3.capture2e("bash", "-n", stdin_data: text("completion", "bash")).last.success?).to be(true)
  end

  it "writes a zsh script zsh accepts" do
    skip "zsh not installed" unless system("which zsh > /dev/null 2>&1")

    expect(Open3.capture2e("zsh", "-n", stdin_data: text("completion", "zsh")).last.success?).to be(true)
  end

  it "answers an unknown shell with the usage line and status 2" do
    expect(run("completion", "pwsh")).to eq(["usage: hecks completion <bash|zsh|fish>", 2])
  end

  it "answers a missing shell with status 2" do
    expect(status("completion")).to eq(2)
  end
end
