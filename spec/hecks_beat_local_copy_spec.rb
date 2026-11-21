# frozen_string_literal: true

require "spec_helper"
require "support/train_copy_with_locals"
require "hecks/signalbox/adapters/looking"
require "hecks/hecks/adapters/main_integration"

# The beat job's copy step makes the train copy's local files the main checkout's.
RSpec.describe Hecks::Adapters::MainIntegration::LocalCopy do
  include_context "with a train copy"

  def run_step(dir = copy) = Open3.capture3("sh", "-c", described_class.step, chdir: dir)

  it "copies a missing local file, so the view counts none" do
    run_step
    expect(Hecks::Adapters::Looking::View.new(copy).facts[:missing]).to eq(0)
  end

  it "replaces a stale local file with the main checkout's" do
    File.write(File.join(copy, "agents.local.world"), "stale")
    run_step
    expect(File.read(File.join(copy, "agents.local.world"))).to eq("primary")
  end

  it "copies nothing from the skipped directories" do
    run_step
    expect(File).not_to exist(File.join(copy, "vendor", "x.local.world"))
  end

  it "ends well in the main checkout itself" do
    expect(run_step(repo).last).to be_success
  end
end
