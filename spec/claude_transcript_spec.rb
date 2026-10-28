require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/hecks/hecks/adapters/claude_transcript"

# The transcript heuristic behind `AgentRun.Tidy`: a person spoke when a user message follows the
# brief that is not a tool result. Anything unreadable counts as spoken.
RSpec.describe Hecks::Adapters::ClaudeTranscript do
  let(:projects) { Dir.mktmpdir("transcripts") }
  let(:reader) { described_class.new(projects: projects) }

  after { FileUtils.rm_rf(projects) }

  def write(lines, id: "abc")
    FileUtils.mkdir_p(File.join(projects, "p"))
    File.write(File.join(projects, "p", "#{id}.jsonl"), lines.is_a?(String) ? lines : lines.map do |l|
      JSON.generate(l)
    end.join("\n"))
  end

  def user(content) = { type: "user", message: { content: content } }
  def result = user([{ type: "tool_result", content: "x" }])

  it "is false for a brief followed only by tool results and replies from the assistant" do
    write([user("brief"), result, { type: "assistant", message: {} }, result])

    expect(reader.taken_over?("abc")).to be(false)
  end

  it "is true when a second user message follows" do
    write([user("brief"), result, user("and one more thing")])

    expect(reader.taken_over?("abc")).to be(true)
  end

  def human(content) = user(content).merge(origin: { kind: "human" })

  def origins = %w[task-notification peer auto-continuation].map { |k| user("x").merge(origin: { kind: k }) }
  def tagged = %w[system-reminder command-name local-command-stdout].map { |t| user("<#{t}>x</#{t}>") }
  def flagged = [{ isMeta: true }, { isSidechain: true }, { toolUseResult: {} }].map { |f| user("x").merge(f) }
  def automatic_entries = origins + tagged + flagged

  it "does not count automatic user entries as a person" do
    write([human("brief"), *automatic_entries])

    expect(reader.taken_over?("abc")).to be(false)
  end

  it "counts a reply with a human origin as a person" do
    write([human("brief"), *automatic_entries, human("board")])

    expect(reader.taken_over?("abc")).to be(true)
  end

  it "is true when the transcript is missing" do
    expect(reader.taken_over?("absent")).to be(true)
  end

  it "is true when the transcript cannot be parsed" do
    write("{not json")

    expect(reader.taken_over?("abc")).to be(true)
  end
end
