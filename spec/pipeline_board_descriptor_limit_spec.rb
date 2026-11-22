# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board starts with its soft descriptor limit raised toward the hard limit, never lowered,
# and a limit it cannot raise is logged, not fatal.
RSpec.describe Hecks::Adapters::PipelineBoard::DescriptorLimit do
  let(:logged) { [] }
  let(:process) { double("process", getrlimit: [256, 100_000], setrlimit: nil) }

  def raise_limit = described_class.raise!(log: ->(line) { logged << line }, process: process)

  it "raises the soft limit to the named wanted limit when the hard limit allows" do
    raise_limit
    expect(process).to have_received(:setrlimit).with(Process::RLIMIT_NOFILE, described_class::WANTED, 100_000)
  end

  it "logs the limit it got" do
    raise_limit
    expect(logged.first).to include(described_class::WANTED.to_s)
  end

  it "stays within the hard limit" do
    allow(process).to receive(:getrlimit).and_return([256, 1024])
    raise_limit
    expect(process).to have_received(:setrlimit).with(Process::RLIMIT_NOFILE, 1024, 1024)
  end

  it "never lowers a limit that is already higher" do
    allow(process).to receive(:getrlimit).and_return([50_000, 100_000])
    raise_limit
    expect(process).not_to have_received(:setrlimit)
  end

  it "logs a refusal and goes on" do
    allow(process).to receive(:setrlimit).and_raise(Errno::EPERM)
    raise_limit
    expect(logged.first).to match(/could not raise/)
  end
end
