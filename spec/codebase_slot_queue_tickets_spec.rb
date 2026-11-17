# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/heavy_slots"

# What a ticket is and is not, and which jobs go first.
RSpec.describe Hecks::Adapters::Codebase::SlotQueue do
  let(:dir) { Dir.mktmpdir("slot-queue") }

  after { FileUtils.rm_rf(dir) }

  it "makes a ticket that is not read as a holder of a place" do
    queue = described_class.new(dir).join
    expect(Hecks::Adapters::Codebase::SlotText.holders(dir, 1)).to eq([])
    queue.leave
  end

  it "ranks a job started by the train's push before every other job", :aggregate_failures do
    train = { "GIT_CONFIG_PARAMETERS" => "'hecks.trainCarry=abc123'" }
    expect(described_class.priority_of(train)).to eq(described_class::TRAIN)
    expect(described_class.priority_of({})).to eq(described_class::ORDINARY)
  end

  it "ranks a job marked urgent between the train's and the others", :aggregate_failures do
    urgent = { "HECKS_HEAVY_PRIORITY" => "urgent" }
    expect(described_class.priority_of(urgent)).to eq(described_class::URGENT)
    expect(described_class::TRAIN).to be < described_class::URGENT
    expect(described_class::URGENT).to be < described_class::ORDINARY
  end
end
