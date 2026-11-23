# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# The session-start inbox watch: a session is told the one Monitor command that watches its own
# inbox, and that command wakes it with one line per unread message, whichever run it is.
RSpec.describe "the session inbox watch" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("inbox_watch") }
  let(:dev) { File.join(dir, "dev") }
  let(:session) { "aedefaa0-1111-2222-3333-444444444444" }

  let(:ledger_sql) do
    <<~SQL
      create table hand_run (run TEXT, session TEXT);
      create table seat_cursor (seat TEXT, position TEXT);
      create table events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, aggregate TEXT, aggregate_id TEXT, payload TEXT, occurred_at TEXT);
    SQL
  end

  before do
    FileUtils.mkdir_p([File.join(dir, "exe"), File.join(dir, ".claude"), dev])
    FileUtils.cp_r(File.join(root, ".claude/hooks"), File.join(dir, ".claude"))
    stand_in_launcher
    sql("agent_run.db", "create table agent_run (run TEXT, session TEXT, status TEXT);")
    sql("agents.db", ledger_sql)
  end

  after { FileUtils.remove_entry(dir) }

  def stand_in_launcher
    path = File.join(dir, "exe/hecks")
    File.write(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"#{dir}/calls\"\ncat \"#{dir}/inbox\" 2>/dev/null\n")
    File.chmod(0o755, path)
  end

  def sql(db, statement) = Open3.capture2("sqlite3", File.join(dev, db), stdin_data: statement)

  def env = { "CLAUDE_PROJECT_DIR" => dir, "HECKS_DEV_DIR" => dev, "HECKS_WATCH_TURNS" => "1" }

  def start_context
    out, = Open3.capture3(env, File.join(dir, ".claude/hooks/session_inbox_watch.sh"),
                          stdin_data: JSON.generate(session_id: session))
    JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
  end

  def watch_lines
    out, = Open3.capture3(env, File.join(dir, ".claude/hooks/inbox_watch.sh"), session)
    out.lines(chomp: true)
  end

  def inbox(*ids, to: "run-a")
    event = "insert into events (name, aggregate, aggregate_id, payload) values ('MessageAddressed', 'Message', "
    payload = %('{"recipient":{"value":"#{to}"}}')
    rows = ids.map { |id| "#{event}'#{id}', #{payload});" }
    sql("agents.db", "insert into seat_cursor values ('{\"value\":\"#{to}\"}', '{\"value\":0}'); #{rows.join}")
  end

  it "names a started run's key and the Monitor command that watches it", :aggregate_failures do
    sql("agent_run.db", "insert into agent_run values ('{\"value\":\"run-a\"}', '{\"value\":\"aedefaa0\"}', 'started');")
    expect(start_context).to include("Monitor", "inbox_watch.sh", session, "run-a")
  end

  it "names a registered hand run's key" do
    sql("agents.db", "insert into hand_run values ('{\"value\":\"miette\"}', '{\"value\":\"aedefaa0\"}');")
    expect(start_context).to include("miette")
  end

  it "tells a session with no run to register, then watch" do
    expect(start_context).to include("HandRun.register!", "Monitor")
  end

  it "emits one line per unread message, the id only" do
    sql("agent_run.db", "insert into agent_run values ('{\"value\":\"run-a\"}', '{\"value\":\"aedefaa0\"}', 'started');")
    inbox("m1", "m2")
    expect(watch_lines).to match([a_string_including("m1"), a_string_including("m2")])
  end

  it "resolves the key when it is asked, so a run registered after the start is heard" do
    inbox("m9", to: "late")
    sql("agents.db", "insert into hand_run values ('{\"value\":\"late\"}', '{\"value\":\"aedefaa0\"}');")
    expect(watch_lines.join).to include("m9", "late")
  end

  it "reads the cursor with no boot of the launcher", :aggregate_failures do
    sql("agent_run.db", "insert into agent_run values ('{\"value\":\"run-a\"}', '{\"value\":\"aedefaa0\"}', 'started');")
    inbox("m1")
    expect(watch_lines).to match([a_string_including("m1")])
    expect(File.exist?(File.join(dir, "calls"))).to be(false)
  end

  it "says nothing while there is no mail" do
    sql("agent_run.db", "insert into agent_run values ('{\"value\":\"run-a\"}', '{\"value\":\"aedefaa0\"}', 'started');")
    expect(watch_lines).to be_empty
  end
end
