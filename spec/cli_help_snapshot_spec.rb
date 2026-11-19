require "spec_helper"
require "fileutils"
require_relative "support/cli_help_launcher"
require_relative "support/cli_help_mask"

# The launcher's help, pinned as a reviewed diff: bare `hecks`, `hecks --help`, and each
# module's listing, with every description masked (`CliHelpMask`). The golden holds the names,
# headings and layout, so a branch that rewords a command leaves it untouched; what each line
# says is checked against the bluebooks by `spec/cli_help_descriptions_spec.rb`. A layout or
# name change shows up as a failing example naming the first line that moved. Regenerate with
# SNAPSHOT=rewrite only after reading the diff.
RSpec.describe "exe/hecks help snapshots", :io do
  def golden_dir = File.expand_path("golden/cli", __dir__)

  def golden_path(name) = File.join(golden_dir, "#{name}.txt")

  def record(name, actual)
    FileUtils.mkdir_p(golden_dir)
    File.write(golden_path(name), actual)
  end

  def first_difference(expected, actual) = CliHelpMask.first_difference(expected, actual)

  CliHelpLauncher::SNAPSHOTS.each do |name, argv|
    it "matches the #{name} snapshot" do
      actual = CliHelpMask.mask(CliHelpLauncher.output(argv))
      record(name, actual) if ENV["SNAPSHOT"] == "rewrite"
      expect(first_difference(File.read(golden_path(name)), actual)).to be_nil
    end
  end

  it "matches its golden when a branch rewords a command description", :aggregate_failures do
    help = CliHelpLauncher.output(["build"])
    reworded = help.sub(/^(    project_rust!\s+).*$/) { "#{Regexp.last_match(1)}Write a domain's Rust, said again" }
    expect(reworded).not_to eq(help)
    expect(first_difference(File.read(golden_path("module-build")), CliHelpMask.mask(reworded))).to be_nil
  end

  it "names the first line that moved" do
    expected = File.read(golden_path("module-deliver"))
    changed = expected.sub("deliver —", "delivers —")
    expect(first_difference(expected, changed)).to include("line 1:")
  end

  it "reports a line added at the end" do
    expected = File.read(golden_path("module-deliver"))
    expect(first_difference(expected, "#{expected}extra\n")).to include("extra")
  end
end
