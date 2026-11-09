# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# A board that grows or stands for long restarts itself, as the command that started it.
RSpec.describe Hecks::Adapters::PipelineBoard::BoardRestart do
  let(:limits) { { rss_mb: 1024.0, age_hours: 24.0, refresh_seconds: 30.0 } }
  let(:clock) { [Time.utc(2026, 11, 9)] }
  let(:restarts) { [] }
  let(:memory) { [100.0] }

  def board
    described_class.new(limits: limits, command: %w[ruby exe/hecks board], memory: -> { memory.first },
                        now: -> { clock.first }, restart: ->(argv) { restarts << argv })
  end

  it "keeps running while it is small and young", :aggregate_failures do
    expect(board.check).to be_nil
    expect(restarts).to be_empty
  end

  it "restarts as the command that started it once it is over the memory limit", :aggregate_failures do
    memory[0] = 2048.0
    expect(board.check).to eq(:memory)
    expect(restarts).to eq([%w[ruby exe/hecks board]])
  end

  it "restarts after the age limit" do
    started = board
    clock[0] += 25 * 3600
    expect(started.check).to eq(:age)
  end

  it "reads its limits from the Hecks world, with defaults for what it leaves out" do
    world = Struct.new(:rows) { def for_verb(_verb) = rows }.new({ refresh_seconds: 60, rss_mb: 512 })
    registry = Struct.new(:world) { def world(*) = self[:world] }.new(world)
    expect(described_class.limits(registry)).to eq(refresh_seconds: 60.0, rss_mb: 512.0, age_hours: 24.0)
  end
end
