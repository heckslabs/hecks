# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"
require "hecks/pipeline_board/adapters/board_supervisor"

# A board that does not answer is stopped (asked, then killed after the grace) and started again.
RSpec.describe Hecks::Adapters::BoardSupervisor, "#restart" do
  let(:signals) { [] }
  let(:started) { [] }

  def supervisor(alive:)
    described_class.new(listeners: ->(_port) { [41] }, signal: ->(*args) { signals << args }, alive: alive,
                        start: ->(port) { started << port }, pause: ->(_seconds) {}, limits: -> { { grace: 0 } })
  end

  it "stops the listener, kills one that ignores the stop, and starts the board again", :aggregate_failures do
    supervisor(alive: ->(_pid) { true }).restart(port: { value: 4747 })
    expect(signals).to eq([["TERM", 41], ["KILL", 41]])
    expect(started).to eq([4747])
  end

  it "does not kill a listener that stopped when asked" do
    supervisor(alive: ->(_pid) { false }).restart(port: 4747)
    expect(signals).to eq([["TERM", 41]])
  end
end
