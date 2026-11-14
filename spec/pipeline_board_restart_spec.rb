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
  let(:command) { %w[ruby exe/hecks pipeline_board PipelineBoard.serve!] }

  def board(code_moved: -> { false })
    described_class.new(limits: limits, command: command, memory: -> { memory.first }, code_moved: code_moved,
                        now: -> { clock.first }, restart: ->(argv) { restarts << argv })
  end

  it "restarts at once when its own code changed on disk, even when young and small", :aggregate_failures do
    expect(board(code_moved: -> { true }).check).to eq(:code)
    expect(restarts).to eq([command])
  end

  it "keeps running while it is small and young", :aggregate_failures do
    expect(board.check).to be_nil
    expect(restarts).to be_empty
  end

  it "restarts as the command that started it once it is over the memory limit", :aggregate_failures do
    memory[0] = 2048.0
    expect(board.check).to eq(:memory)
    expect(restarts).to eq([command])
  end

  it "restarts after the age limit" do
    started = board
    clock[0] += 25 * 3600
    expect(started.check).to eq(:age)
  end

  it "reads its limits from the Hecks world, with defaults for what it leaves out" do
    world = Struct.new(:rows) { def for_verb(_verb) = rows }.new({ refresh_seconds: 60, rss_mb: 512 })
    registry = Struct.new(:world) { def world(*) = self[:world] }.new(world)
    expect(described_class.limits(registry)).to eq(refresh_seconds: 60.0, rss_mb: 512.0, age_hours: 24.0,
                                                   min_uptime_seconds: 600.0, loaded_refresh_seconds: 60.0)
  end

  def large_board
    memory[0] = 4096.0
    described_class.new(limits: limits.merge(min_uptime_seconds: 600.0), command: %w[ruby board],
                        memory: -> { memory.first }, now: -> { clock.first }, restart: ->(argv) { restarts << argv })
  end

  it "does not restart before its minimum uptime, however large it is" do
    expect(large_board.check).to be_nil
  end

  it "restarts once the minimum uptime has passed" do
    board = large_board
    clock[0] += 601
    expect(board.check).to eq(:memory)
  end

  it "takes the script as an absolute path, so a restart does not depend on the directory" do
    expect(described_class.new(limits: limits).instance_variable_get(:@command)[1]).to start_with("/")
  end
end
