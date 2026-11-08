# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_journal"
require_relative "support/turn_log_helpers"

# The console block of a `TurnFinished`: a projection of the event, read from a scratch event log.
RSpec.describe "the console block of a TurnFinished" do
  include TurnLogHelpers

  let(:dir) { Dir.mktmpdir("turns") }
  let(:log) { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  it "is headed with the role and time", :aggregate_failures do
    block = journal_over(full_turn).turn_block[:text].lines.map(&:chomp)
    expect(block.first).to eq("--- turn finished: orchestrator @ 2026-11-08T00:41Z ---")
    expect(block).to include("verdict   routed", "landed    399811d02 recognise a squash-carried train")
  end

  it "aligns main and leaves out the fields the turn lacks", :aggregate_failures do
    block = journal_over(full_turn).turn_block[:text]
    expect(block).to include("main      882b14eb4 +9 local, clean")
    expect(block).not_to include("dispatched")
  end

  it "prints the block of the run it is asked for" do
    journal = journal_over(turn_line("r1", "t1", "blocked"), turn_line("r2", "t2", "routed"))
    expect(journal.turn_block(run: "r1")[:text]).to include("verdict   blocked")
  end
end
