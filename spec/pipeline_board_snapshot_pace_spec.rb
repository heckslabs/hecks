# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"
require_relative "support/snapshot_freeze_world"

# How often the held state is read and how a reader tells it moved: a loaded machine is read at
# the slower period however often it is woken, and the version moves only when the state does.
RSpec.describe Hecks::Adapters::PipelineBoard::Snapshot do
  include SnapshotFreezeWorld

  after { @snap&.stop }

  let(:reads) { [] }
  let(:held_for) { Queue.new }

  # The wait that holds a loaded machine's read: it says how long it was asked to wait and
  # never returns, so a second read would show.
  def holding
    lambda do |seconds|
      held_for << seconds
      Queue.new.pop
    end
  end

  def paced(loaded:, state: -> { { generated_at: reads.size.to_s, stages: [] } })
    guard = instance_double(Hecks::Adapters::PipelineBoard::LoadGuard, loaded?: loaded)
    source = -> { reads.push(1) && state.call }
    @snap = described_class.new(source: source, every: 0.05, loaded_every: 30, stand: -> { guard }, wait: holding).start
  end

  it "holds a loaded machine's next read for the loaded period, woken or not", :aggregate_failures do
    paced(loaded: true)
    3.times { @snap.refresh_now }
    expect(Timeout.timeout(5) { held_for.pop }).to be_within(1).of(30)
    expect(reads.size).to eq(1)
  end

  it "reads at its period when the machine is not loaded", :aggregate_failures do
    paced(loaded: false)
    until_held { reads.size > 2 }
    expect(held_for).to be_empty
  end

  it "keeps the version while the state stands still", :aggregate_failures do
    paced(loaded: false)
    until_held { reads.size >= 3 }
    expect(@snap.latest[:version]).to eq(1)
  end

  it "moves the version when the state moves" do
    paced(loaded: false, state: -> { { generated_at: "g", stages: [reads.size] } })
    until_held { reads.size >= 3 }
    expect(@snap.latest[:version]).to be >= 2
  end

  it "takes the loaded period from the board_restart limits" do
    limits = Hecks::Adapters::PipelineBoard::BoardRestart.limits(nil)
    expect(limits[:loaded_refresh_seconds]).to eq(60.0)
  end
end
