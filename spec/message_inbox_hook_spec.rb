# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# The inbox hook, run after each tool step against scratch ledgers and a stand-in `exe/hecks`: a
# seat hears the messages addressed to it past its cursor, and the cursor moves only over a
# message whose text the hook printed. The read boots nothing and the mark is a line in the spool.
RSpec.describe "the message inbox hook" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("message_inbox") }
  let(:dev) { File.join(dir, "dev") }
  let(:spool) { File.join(dev, "mail", "spool.jsonl") }

  let(:runs_sql) do
    <<~SQL
      create table agent_run (run TEXT, session TEXT, status TEXT);
      insert into agent_run values ('{"value":"run-a"}', '{"value":"aedefaa0"}', 'started');
    SQL
  end
  let(:ledger_sql) do
    <<~SQL
      create table events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, aggregate TEXT, aggregate_id TEXT, payload TEXT, occurred_at TEXT);
      create table seat_cursor (seat TEXT, position TEXT);
      create table hand_run (run TEXT, session TEXT);
    SQL
  end

  before do
    FileUtils.mkdir_p([File.join(dir, ".claude/hooks"), File.join(dir, "exe"), dev])
    FileUtils.cp(Dir[File.join(root, ".claude/hooks/{message_inbox,mail_mark}.sh")], File.join(dir, ".claude/hooks"))
    stand_in_launcher
    sql(File.join(dev, "agent_run.db"), runs_sql)
    sql(File.join(dev, "agents.db"), ledger_sql)
  end

  after { FileUtils.remove_entry(dir) }

  def stand_in_launcher
    path = File.join(dir, "exe/hecks")
    File.write(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"#{dir}/calls\"\n")
    File.chmod(0o755, path)
  end

  def sql(db, statement) = Open3.capture2("sqlite3", db, stdin_data: statement)

  def ledger(statement) = sql(File.join(dev, "agents.db"), statement)

  def cursor_at(position, seat: "run-a")
    ledger("insert into seat_cursor values ('{\"value\":\"#{seat}\"}', '{\"value\":#{position}}');")
  end

  def say(key: "m1", to: "run-a", body: "use the smaller version", payload: nil)
    fields = { message: key, recipient: to, sender: "miette", kind: "answer", body: body, in_reply_to: "" }
    json = payload || JSON.generate(fields.transform_values { |value| { value: value } })
    ledger("insert into events (name, aggregate, aggregate_id, payload) values ('MessageAddressed', 'Message', '#{key}', '#{json}');")
  end

  def step(session: "aedefaa0-1111-2222-3333-444444444444")
    env = { "CLAUDE_PROJECT_DIR" => dir, "HECKS_DEV_DIR" => dev }
    out, = Open3.capture3(env, File.join(dir, ".claude/hooks/message_inbox.sh"), stdin_data: JSON.generate(session_id: session))
    out
  end

  def context(out) = JSON.parse(out).dig("hookSpecificOutput", "additionalContext")

  def calls = File.exist?(File.join(dir, "calls")) ? File.read(File.join(dir, "calls")) : ""

  def marks = File.exist?(spool) ? File.readlines(spool).map { |line| JSON.parse(line) } : []

  it "hands the seat each message past its cursor with its sender, kind, body, id and how to answer" do
    cursor_at(0)
    say
    expect(context(step)).to include("miette", "answer", "use the smaller version", "m1", "Message.send!", "in_reply_to")
  end

  it "moves the cursor over a message it printed, with a line in the spool and no boot", :aggregate_failures do
    cursor_at(0)
    say
    step
    expect(marks).to eq([{ "advance" => "run-a", "to" => 1 }])
    expect(calls).to be_empty
  end

  it "does not offer a message again once its advance waits in the spool" do
    cursor_at(0)
    say
    step
    expect(step).to be_empty
  end

  it "reads a seat with no cursor from now: it hears none of the past and marks the newest event", :aggregate_failures do
    say
    expect(step).to be_empty
    expect(marks).to eq([{ "open" => "run-a", "to" => 1 }])
  end

  it "says nothing and marks nothing when the cursor is past every message", :aggregate_failures do
    cursor_at(1)
    say
    expect(step).to be_empty
    expect(marks).to be_empty
  end

  it "leaves the cursor before a message whose text could not be built, and prints nothing past it", :aggregate_failures do
    cursor_at(0)
    say(key: "m1", payload: "not json")
    say(key: "m2", body: "later")
    expect(step).to be_empty
    expect(marks).to be_empty
  end

  it "advances only over the messages printed before a failure", :aggregate_failures do
    cursor_at(0)
    say(key: "m1")
    say(key: "m2", payload: "not json")
    expect(context(step)).to include("m1")
    expect(marks).to eq([{ "advance" => "run-a", "to" => 1 }])
  end

  it "does not hear a message for another seat, nor move the cursor of another seat", :aggregate_failures do
    cursor_at(0)
    say(to: "run-b")
    expect(step).to be_empty
    expect(marks).to be_empty
  end

  it "says nothing and marks nothing to a session that is no run", :aggregate_failures do
    cursor_at(0)
    say
    expect(step(session: "ffffffff-0000")).to be_empty
    expect(marks).to be_empty
  end
end
