# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# The inbox hook, run after each tool step against scratch ledgers and a stand-in `exe/hecks`: a
# message sent to a working run appears in its session at once and is marked read, a step with
# nothing unread boots nothing, and a session with no run hears nothing.
RSpec.describe "the message inbox hook" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("message_inbox") }
  let(:dev) { File.join(dir, "dev") }

  before do
    FileUtils.mkdir_p([File.join(dir, ".claude/hooks"), File.join(dir, "exe"), dev])
    FileUtils.cp(File.join(root, ".claude/hooks/message_inbox.sh"), File.join(dir, ".claude/hooks"))
    stand_in_launcher
    sql(File.join(dev, "agent_run.db"), "create table agent_run (run TEXT, session TEXT, status TEXT);" \
        "insert into agent_run values ('{\"value\":\"run-a\"}', '{\"value\":\"aedefaa0\"}', 'started');")
    sql(File.join(dev, "agents.db"), "create table message (message TEXT, recipient TEXT, sender TEXT, kind TEXT, " \
        "body TEXT, in_reply_to TEXT, status TEXT); create table hand_run (run TEXT, session TEXT);")
  end

  after { FileUtils.remove_entry(dir) }

  def stand_in_launcher
    path = File.join(dir, "exe/hecks")
    File.write(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"#{dir}/calls\"\n")
    File.chmod(0o755, path)
  end

  def sql(db, statement) = Open3.capture2("sqlite3", db, stdin_data: statement)

  def say(to: "run-a", body: "use the smaller version", status: "sent")
    sql(File.join(dev, "agents.db"), "insert into message values ('{\"value\":\"m1\"}', '{\"value\":\"#{to}\"}', " \
        "'{\"value\":\"miette\"}', '{\"value\":\"answer\"}', '{\"value\":\"#{body}\"}', '{\"value\":\"\"}', '#{status}');")
  end

  def step(session: "aedefaa0-1111-2222-3333-444444444444")
    env = { "CLAUDE_PROJECT_DIR" => dir, "HECKS_DEV_DIR" => dev }
    out, = Open3.capture3(env, File.join(dir, ".claude/hooks/message_inbox.sh"), stdin_data: JSON.generate(session_id: session))
    out
  end

  def calls = File.exist?(File.join(dir, "calls")) ? File.read(File.join(dir, "calls")) : ""

  it "hands the run's session each unread message with its sender, kind, body, id and how to answer" do
    say
    context = JSON.parse(step).dig("hookSpecificOutput", "additionalContext")
    expect(context).to include("miette", "answer", "use the smaller version", "m1", "Message.send!", "in_reply_to")
  end

  it "marks the message read through Message.read!" do
    say
    step
    expect(calls.lines(chomp: true)).to include("Message.read!", "to=m1")
  end

  it "says nothing and boots nothing when the inbox is empty", :aggregate_failures do
    say(status: "read")
    expect(step).to be_empty
    expect(calls).to be_empty
  end

  it "says nothing to a session that is no run" do
    say
    expect(step(session: "ffffffff-0000")).to be_empty
  end

  it "does not hear a message for another run" do
    say(to: "run-b")
    expect(step).to be_empty
  end
end
