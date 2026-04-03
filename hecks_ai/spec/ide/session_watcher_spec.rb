# Hecks::AI::IDE::SessionWatcher
#
# Unit tests for session JSONL tailing: user echo, assistant forwarding,
# tool result extraction, and IDE prompt deduplication.
#
# Uses IO.pipe to avoid filesystem I/O and sleep-based polling.
#
require "json"

RSpec.describe "SessionWatcher" do
  let(:events) { [] }
  let(:mutex) { Mutex.new }
  let(:session_id) { "test-session-abc" }
  let(:tmpdir) { Dir.mktmpdir }

  before do
    $LOAD_PATH.unshift(File.expand_path("../../lib", __dir__)) unless $LOAD_PATH.any? { |p| p.include?("hecks_ai/lib") }
    require "hecks_ai/ide/session_watcher"
  end

  after { FileUtils.rm_rf(tmpdir) }

  def build_watcher(reader)
    Hecks::AI::IDE::SessionWatcher.new(session_id, events, mutex, session_dir: tmpdir, io: reader, poll_interval: 0.005)
  end

  def wait_for_events(count, timeout: 0.3)
    deadline = Time.now + timeout
    sleep 0.001 while events.size < count && Time.now < deadline
  end

  it "forwards assistant text entries" do
    reader, writer = IO.pipe
    watcher = build_watcher(reader)
    watcher.start

    writer.puts(JSON.generate(type: "assistant", message: { content: [{ type: "text", text: "hello" }] }))
    wait_for_events(1)
    watcher.stop
    writer.close

    parsed = JSON.parse(events.first)
    expect(parsed["type"]).to eq("assistant")
  end

  it "emits user_echo for user entries" do
    reader, writer = IO.pipe
    watcher = build_watcher(reader)
    watcher.start

    writer.puts(JSON.generate(type: "user", message: { role: "user", content: "test prompt" }))
    wait_for_events(1)
    watcher.stop
    writer.close

    parsed = JSON.parse(events.first)
    expect(parsed["type"]).to eq("user_echo")
    expect(parsed["message"]["content"]).to eq("test prompt")
  end

  it "suppresses user_echo after mark_ide_prompt!" do
    reader, writer = IO.pipe
    watcher = build_watcher(reader)
    watcher.start

    watcher.mark_ide_prompt!
    writer.puts(JSON.generate(type: "user", message: { role: "user", content: "from ide" }))
    sleep 0.02

    expect(events).to be_empty
    watcher.stop
    writer.close
  end

  it "extracts tool_result from user entries" do
    reader, writer = IO.pipe
    watcher = build_watcher(reader)
    watcher.start

    writer.puts(JSON.generate(
      type: "user",
      message: {
        role: "user",
        content: [
          { type: "tool_result", tool_use_id: "toolu_abc", content: [{ type: "text", text: "command output" }] }
        ]
      }
    ))
    wait_for_events(1)
    watcher.stop
    writer.close

    parsed = JSON.parse(events.first)
    expect(parsed["type"]).to eq("tool_result")
    expect(parsed["tool_use_id"]).to eq("toolu_abc")
    expect(parsed["output"]).to eq("command output")
  end

  it "extracts tool_result with string content" do
    reader, writer = IO.pipe
    watcher = build_watcher(reader)
    watcher.start

    writer.puts(JSON.generate(
      type: "user",
      message: {
        role: "user",
        content: [
          { type: "tool_result", tool_use_id: "toolu_xyz", content: "simple output" }
        ]
      }
    ))
    wait_for_events(1)
    watcher.stop
    writer.close

    parsed = JSON.parse(events.first)
    expect(parsed["type"]).to eq("tool_result")
    expect(parsed["output"]).to eq("simple output")
  end
end
