# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/restart_notes"

# What the board's header says about the times it restarted itself.
RSpec.describe Hecks::Adapters::PipelineBoard::RestartNotes do
  let(:path) { File.join(Dir.mktmpdir, "restarts.json") }

  it "reads nothing when the board never restarted itself" do
    expect(described_class.reading(path: path)).to be_nil
  end

  it "says the restart and the missed answers behind it", :aggregate_failures do
    described_class.record(misses: 4, path: path, now: Time.utc(2026, 11, 15, 11, 5))
    note = described_class.reading(path: path)[:notes].last
    expect(note).to match(/\Arestarted itself at \d\d:\d\d after 4 missed answers\z/)
  end

  it "keeps only the newest notes" do
    (described_class::KEPT + 5).times { |count| described_class.record(misses: count, path: path) }
    expect(JSON.parse(File.read(path)).length).to eq(described_class::KEPT)
  end

  it "reads nothing from a file that is not notes" do
    File.write(path, "not json")
    expect(described_class.reading(path: path)).to be_nil
  end

  it "carries no restart in the state when none was noted" do
    stub_const("Hecks::Adapters::PipelineBoard::RestartNotes::PATH", path)
    expect(described_class.with_state).to eq(board_restarts: nil)
  end
end
