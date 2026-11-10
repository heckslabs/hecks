# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/claude_closing_message"

# Builds transcripts in a temporary projects directory, shaped as `claude` writes them.
module ClosingMessageTranscripts
  def assistant(*parts, sidechain: false)
    { type: "assistant", isSidechain: sidechain, message: { content: parts } }
  end

  def text(words) = { type: "text", text: words }

  def transcript(*entries, id: "abc123-0000-full")
    FileUtils.mkdir_p(File.join(projects, "-repo"))
    File.write(File.join(projects, "-repo", "#{id}.jsonl"), entries.map { |entry| "#{JSON.generate(entry)}\n" }.join)
  end
end

# The whole of a session's closing message, read from its transcript.
RSpec.describe Hecks::Adapters::ClaudeClosingMessage do
  include ClosingMessageTranscripts

  let(:projects) { Dir.mktmpdir("closing-message") }
  let(:reader) { described_class.new(projects: projects) }

  it "reads the last assistant entry with text, whole, by a short id's prefix" do
    transcript(assistant(text("First.")), assistant(text("Head.\n"), text("Verdict: sound")),
               assistant({ type: "tool_use", name: "Read" }), { type: "user", message: { content: "ok" } })
    expect(reader.of("abc123")).to eq("Head.\nVerdict: sound")
  end

  it "passes over a sidechain's message" do
    transcript(assistant(text("Mine.")), assistant(text("A subagent's."), sidechain: true))
    expect(reader.of("abc123")).to eq("Mine.")
  end

  it "answers empty when a short id matches more than one transcript" do
    transcript(assistant(text("One.")))
    transcript(assistant(text("Two.")), id: "abc123-1111-full")
    expect(reader.of("abc123")).to eq("")
  end

  it "answers empty for a session with no transcript, or no id" do
    expect([reader.of("nobody"), reader.of("")]).to eq(["", ""])
  end

  it "takes glob characters in an id literally" do
    transcript(assistant(text("One.")))
    expect(reader.of("abc*")).to eq("")
  end
end
