# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/harness/adapters/crew_usage"

# Harness::Baseline.reading reports the crew's tokens per minute and cache hit rate by role over one
# sixty-minute window, and the items finished per hour, from transcripts and the event tap.
RSpec.describe Hecks::Adapters::CrewUsage do
  let(:dir) { Dir.mktmpdir("crew_usage") }
  let(:tap) { File.join(dir, "events.jsonl") }
  let(:start) { "2026-11-20T09:00:00Z" }

  def call(id, at, usage = { input_tokens: 10, output_tokens: 20, cache_creation_input_tokens: 30, cache_read_input_tokens: 60 })
    JSON.generate(type: "assistant", timestamp: at, message: { id: id, usage: usage })
  end

  def transcript(path, lines)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, lines.join("\n"))
  end

  def reading(**held)
    described_class.new(settings: { projects: dir, tap: tap }).reading(day: "2026-11-20", start: start, **held)[:text]
  end

  before { File.write(tap, "") }

  it "counts a call written as several lines once, by its message id" do
    transcript("#{dir}/p/s.jsonl", [call("m1", "2026-11-20T09:10:00Z"), call("m1", "2026-11-20T09:10:00Z")])
    expect(reading).to include("tokens_per_minute: 2.0")
  end

  it "counts a call with no usage as zero tokens" do
    transcript("#{dir}/p/s.jsonl", [call("m1", "2026-11-20T09:10:00Z", nil)])
    expect(reading).to include("tokens_per_minute: 0.0")
  end

  it "skips a line that is not JSON and says how many" do
    transcript("#{dir}/p/s.jsonl", ["not json", call("m1", "2026-11-20T09:10:00Z")])
    expect(reading).to include("skipped_lines: 1")
  end

  it "counts only calls inside the sixty-minute window" do
    transcript("#{dir}/p/s.jsonl", [call("in", "2026-11-20T09:59:59Z"), call("out", "2026-11-20T10:00:00Z")])
    expect(reading).to include("tokens_per_minute: 2.0")
  end

  it "reads the cache hit rate as cache reads over all input tokens" do
    transcript("#{dir}/p/s.jsonl", [call("m1", "2026-11-20T09:10:00Z")])
    expect(reading).to include("cache_hit_rate: 0.6")
  end

  it "splits a subagent's tokens out by its meta agentType" do
    path = "#{dir}/p/s/subagents/agent-1"
    transcript("#{path}.jsonl", [call("a1", "2026-11-20T09:20:00Z")])
    File.write("#{path}.meta.json", JSON.generate(agentType: "coder"))
    expect(reading).to include("by_role: coder=2.0/0.6")
  end

  it "counts the work items the tap shows finished in the window, per hour" do
    finish = { kind: "event", at: "2026-11-20T09:30:00Z", aggregate: "Tickets::Work", id: "w1", seq: 1 }
    File.write(tap, JSON.generate(finish.merge(event: "WorkFinished")))
    expect(reading).to include("items_per_hour: 1.0")
  end

  it "reads tokens per item as unknown when nothing finished" do
    expect(reading).to include("tokens_per_item: unknown")
  end
end
