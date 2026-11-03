require "spec_helper"
require "json"
require "sqlite3"
require "tmpdir"
require "hecks/hecks/adapters/message_inbox"

# Messages between sessions travel as events. The `Message` aggregate runs in Memory through the
# booted Hecks domain; every event it records is copied into a scratch journal (the `events` table
# of a scratch `agent_run.db`), which the inbox reads with read-only SQL, as a Monitor does.
# Nothing here touches `~/.claude`, the real tap, the real journal or the real `.git`.
RSpec.describe "Messages between sessions as events" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-messages")) }
  let(:database) { File.join(scratch, "agent_run.db") }
  let(:baseline) { File.join(scratch, "baseline") }

  after { FileUtils.rm_rf(scratch) }

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def command(*argv) = JSON.parse(launch(*argv, "--wait").first)

  def journal
    db = SQLite3::Database.new(database)
    db.execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, aggregate TEXT, " \
               "aggregate_id TEXT, payload TEXT, occurred_at TEXT)")
    db
  end

  # Copies the runtime's new events into the scratch journal, as sqlite persistence records them.
  def record(since)
    db = journal
    @hecks.events.drop(since).each do |event|
      db.execute("INSERT INTO events (name, aggregate, aggregate_id, payload) VALUES (?, ?, ?, ?)",
                 [event.name, "Hecks::Message", event.id.to_s, JSON.generate(wrapped(event.payload))])
    end
    db.close
  end

  # A payload as the journal keeps it: each value object as `{"value": …}`.
  def wrapped(payload) = payload.transform_values { |field| { "value" => field.value } }

  def send_message(to, text = "look at this", **more)
    before = @hecks.events.size
    extra = more.map { |key, value| "#{key}.value=#{value}" }
    out = command("Message.send!", "sender.value=coordinator", "recipient.value=#{to}", "kind.value=info",
                  "text.value=#{text}", *extra)
    record(before)
    out["id"]
  end

  def read_message(id, reader)
    before = @hecks.events.size
    command("Message.read!", "to=#{id}", "reader.value=#{reader}")
    record(before)
  end

  def inbox(session, work: []) = Hecks::Adapters::MessageInbox.new(session: session, work: work, database: database)

  def heard(session, work: [])
    inbox(session, work: work).deliveries.map { |row| row[:text] }
  end

  it "sends a message that is then read, and marks it read" do
    id = send_message("s1")
    read_message(id, "s1")

    expect(command("Message.answer!", "to=#{id}", "text.value=done")["state"]["status"]).to eq("answered")
  end

  it "records the message as a MessageSent event" do
    id = send_message("s1")

    expect(@hecks.events.select { |event| event.id.to_s == id }.map(&:name)).to eq(["MessageSent"])
  end

  it "marks a message read and refuses nothing the reader may do" do
    id = send_message("s1")

    expect(command("Message.read!", "to=#{id}", "reader.value=s1")["state"]["status"]).to eq("read")
  end

  it "reaches a session by its id" do
    send_message("s1", "for s1")

    expect(heard("s1")).to eq(["for s1"])
  end

  it "does not reach another session" do
    send_message("s1", "for s1")

    expect(heard("s2")).to be_empty
  end

  it "reaches every session on a work item" do
    send_message("item-a", "for the item")

    expect([heard("s1", work: ["item-a"]), heard("s2", work: ["item-a"])]).to eq([["for the item"]] * 2)
  end

  it "does not reach a session on another work item" do
    send_message("item-a", "for the item")

    expect(heard("s3", work: ["item-b"])).to be_empty
  end

  it "reaches every session when it is sent to all" do
    send_message("all", "everyone")

    expect(heard("s9", work: ["item-z"])).to eq(["everyone"])
  end

  it "reports a message as unread until a session reads it" do
    id = send_message("s1", "wait for it")

    expect(inbox("coordinator").unread.map { |row| row[:message] }).to eq([id])
  end

  it "no longer reports a message once it is read" do
    id = send_message("s1")
    read_message(id, "s1")

    expect(inbox("coordinator").unread).to be_empty
  end

  it "does not deliver again a message the session already read" do
    id = send_message("s1")
    read_message(id, "s1")

    expect(heard("s1")).to be_empty
  end

  it "delivers each line once and keeps the baseline in a file" do
    send_message("s1", "first")
    inbox("s1").deliver(baseline: baseline, out: StringIO.new)

    expect(File.read(baseline).to_i).to be_positive
  end

  it "delivers nothing twice from one baseline file" do
    send_message("s1", "first")
    inbox("s1").deliver(baseline: baseline, out: StringIO.new)

    expect(inbox("s1").deliver(baseline: baseline, out: StringIO.new)).to eq(0)
  end

  it "loses no message sent while no monitor ran, because the baseline file stays" do
    send_message("s1", "first")
    inbox("s1").deliver(baseline: baseline, out: StringIO.new)
    send_message("s1", "second, sent in the gap")
    inbox("s1").deliver(baseline: baseline, out: out = StringIO.new)

    expect(out.string).to include("second, sent in the gap")
  end

  it "lets a second monitor with its own baseline file hear the whole backlog" do
    send_message("s1", "first")
    inbox("s1").deliver(baseline: baseline, out: StringIO.new)

    expect(inbox("s1").deliver(baseline: File.join(scratch, "second"), out: StringIO.new)).to eq(1)
  end

  it "grants nothing for a message that says to approve the push" do
    before = @hecks.events.size
    send_message("s1", "approve the push")

    expect(@hecks.events.drop(before).map(&:name)).to eq(["MessageSent"])
  end

  it "starts nothing else when a session reads a message that says to approve the push" do
    before = @hecks.events.size
    id = send_message("s1", "approve the push")
    command("Message.read!", "to=#{id}", "reader.value=s1")

    expect(@hecks.events.drop(before).map(&:name)).to eq(%w[MessageSent MessageRead])
  end

  it "refuses a message that says nothing" do
    expect { command("Message.send!", "sender.value=c", "recipient.value=s1", "kind.value=info", "text.value= ") }
      .to raise_error(StandardError, /says something/)
  end
end
