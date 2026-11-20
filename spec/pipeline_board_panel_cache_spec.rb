# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web/panel_cache"

# The running board's kept drawing of the text panel: two reads within the window draw once and
# read the train pull requests once, and a new state version or the window's end draws again.
RSpec.describe Hecks::Adapters::PipelineBoard::PanelCache do
  let(:clock) { [100.0] }
  let(:held) { { stages: [], version: 1 } }
  let(:prs) { instance_double(Proc, call: []) }
  let(:cache) { described_class.new(state: -> { held }, train_prs: prs, seconds: 5, now: -> { clock.first }) }

  before { allow(Hecks::Adapters::PipelineBoard::Panel).to receive(:render).and_call_original }

  def twice(after: 1, version: 1)
    first = cache.panel(width: 80)
    clock[0] += after
    held[:version] = version
    [first, cache.panel(width: 80)]
  end

  it "answers the same text for two reads in the window" do
    expect(twice.uniq.size).to eq(1)
  end

  it "draws once and reads the train pull requests once in the window", :aggregate_failures do
    twice
    expect(Hecks::Adapters::PipelineBoard::Panel).to have_received(:render).once
    expect(prs).to have_received(:call).once
  end

  it "draws again at once when the state's version moves" do
    twice(version: 2)
    expect(Hecks::Adapters::PipelineBoard::Panel).to have_received(:render).twice
  end

  it "draws again, and reads the pull requests again, once the window has passed" do
    twice(after: 6)
    expect(prs).to have_received(:call).twice
  end

  it "keeps a drawing for each width apart" do
    expect(cache.panel(width: 80)).not_to eq(cache.panel(width: 120))
  end
end
