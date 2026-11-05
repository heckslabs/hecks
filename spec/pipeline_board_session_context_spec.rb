# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "hecks/pipeline_board/adapters/session_context"

# What a blocked session said last and did just before, read from the tail of its transcript.
RSpec.describe Hecks::Adapters::PipelineBoard::SessionContext do
  let(:dir) { Dir.mktmpdir("session-context") }
  let(:path) { File.join(dir, "transcript.jsonl") }

  after { FileUtils.rm_rf(dir) }

  def line(role, *parts) = "#{JSON.generate("type" => role, "message" => { "content" => parts })}\n"

  def text(value) = { "type" => "text", "text" => value }

  def tool(name, input) = { "type" => "tool_use", "name" => name, "input" => input }

  def transcript(*lines) = File.write(path, lines.join)

  it "answers the last text the session wrote" do
    transcript(line("assistant", text("Starting.")), line("user", text("ok")),
               line("assistant", text("Should I push the branch to origin?")))
    expect(described_class.of(path)[:said]).to eq("Should I push the branch to origin?")
  end

  it "answers its last tool calls, oldest first, at most three" do
    transcript(line("assistant", tool("Bash", { "command" => "a" })), line("assistant", tool("Read", { "file_path" => "b" })),
               line("assistant", tool("Edit", { "file_path" => "c" })), line("assistant", tool("Bash", { "command" => "d" })))
    names = described_class.of(path)[:did].map { |step| step.split.first }
    expect(names).to eq(%w[Read Edit Bash])
  end

  it "answers empty when there is no transcript" do
    expect(described_class.of(File.join(dir, "missing.jsonl"))).to eq(said: "", did: [])
  end

  it "skips a line that is not JSON" do
    transcript("not json\n", line("assistant", text("Still here.")))
    expect(described_class.of(path)[:said]).to eq("Still here.")
  end
end
