# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_journal"
require_relative "support/turn_log_helpers"

# The board's run cards and Stuck list are projections of `TurnFinished`, read from a scratch
# event log.
RSpec.describe "the board's cards and Stuck list from TurnFinished" do
  include TurnLogHelpers

  let(:dir) { Dir.mktmpdir("turns") }
  let(:log) { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  it "gives each run one card whose last word is its newest verdict" do
    journal = journal_over(turn_line("r1", "t1", "blocked"), turn_line("r1", "t2", "routed"))
    expect(JSON.parse(journal.run_cards[:text]).map { |c| [c["run"], c["last_word"]] }).to eq([%w[r1 routed]])
  end

  it "lists the stuck rows of every run's newest turn only" do
    journal = journal_over(turn_line("r1", "t1", "blocked", stuck: [stuck_item]), turn_line("r1", "t2", "routed"))
    expect(JSON.parse(journal.stuck[:text])).to eq([])
  end

  it "lists a stuck row once however many runs report it" do
    journal = journal_over(turn_line("r1", "t1", "blocked", stuck: [stuck_item]),
                           turn_line("r2", "t2", "blocked", stuck: [stuck_item]))
    expect(JSON.parse(journal.stuck[:text]).size).to eq(1)
  end

  it "ignores a TurnFinished that carries no payload" do
    line = "#{JSON.generate(kind: "event", at: "t1", aggregate: "Turn", id: "r1", event: "TurnFinished")}\n"
    expect(journal_over(line).turns).to eq([])
  end
end
