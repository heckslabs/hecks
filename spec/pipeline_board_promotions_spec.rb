# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_journal"
require "hecks/pipeline_board/adapters/pipeline_stages/agent_roles"

# The board's "Promotions to confirm": a recommendation raised by another process reaches the board
# through the event log, because a process of its own holds none in Memory.
RSpec.describe "the board's open promotion recommendations" do
  let(:dir) { Dir.mktmpdir("promotions") }
  let(:log) { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  def event(name, id, at)
    "#{JSON.generate(kind: "event", at: at, aggregate: "Hecks::Agents::PromotionRecommendation", id: id, event: name)}\n"
  end

  def noise = Array.new(700) { |i| event("WorkChecked", "w#{i}", "2026-11-06T09:00:00Z") }

  def open_changes(*lines)
    File.write(log, lines.join)
    journal = Hecks::Adapters::PipelineJournal.new(settings: { trace: ->(*) { { events: [] } }, tap: log, ttl: 0 })
    Hecks::Adapters::PipelineBoard::AgentRoles.recommendations(journal.promotions).map { |row| row[:change] }
  end

  it "lists a PromotionRecommended raised in another process, however much traffic followed it" do
    expect(open_changes(event("PromotionRecommended", "abc123", "2026-11-06T08:00:00Z"), noise)).to eq(["abc123"])
  end

  it "drops a change the owner has settled" do
    expect(open_changes(event("PromotionRecommended", "abc123", "2026-11-06T08:00:00Z"),
                        event("PromotionSettled", "abc123", "2026-11-06T08:05:00Z"))).to eq([])
  end

  it "lists a change again when it is recommended after it was settled" do
    expect(open_changes(event("PromotionRecommended", "abc", "t1"), event("PromotionSettled", "abc", "t2"),
                        event("PromotionRecommended", "abc", "t3"))).to eq(["abc"])
  end
end
