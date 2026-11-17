# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"
require "hecks/pipeline_board/adapters/board_supervisor"

# The supervisor probes the board through its own port and restarts it; it decides nothing else.
RSpec.describe Hecks::Adapters::BoardSupervisor do
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }
  let(:state) { JSON.generate("stale" => false) }

  def supervisor(get: ->(_path, _port) { [200, state] })
    described_class.new(get: get, limits: -> { { answer: 0.2, grace: 0 } })
  end

  it "answers when the page and the state answer" do
    expect(supervisor.probe(port: { value: 4747 })).to eq(answered: 200)
  end

  it "refuses when the page does not answer in its bound" do
    hung = supervisor(get: ->(_path, _port) { Queue.new.pop })
    expect { hung.probe(port: 4747) }.to raise_error(unavailable, %r{did not answer GET /:})
  end

  it "refuses when the board reports its own state as stale" do
    stale = supervisor(get: ->(path, _port) { [200, path == "/" ? "" : JSON.generate("stale" => true)] })
    expect { stale.probe(port: 4747) }.to raise_error(unavailable, "the board's state is stale")
  end

  it "refuses a status other than 200" do
    down = supervisor(get: ->(_path, _port) { [503, ""] })
    expect { down.probe(port: 4747) }.to raise_error(unavailable, "the board answered 503 to GET /")
  end
end
