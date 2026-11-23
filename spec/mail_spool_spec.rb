# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# A send appends one line to the mail spool without booting Hecks, and Hecks ingests the spool one
# line at a time past its cursor.
RSpec.describe "the mail spool" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("mail_spool") }
  let(:spool) { File.join(dir, "mail", "spool.jsonl") }
  let(:hook) { File.join(root, ".claude/hooks/mail_send.sh") }

  after { FileUtils.remove_entry(dir) }

  def send_mail(body, key: "m1")
    Open3.capture3({ "HECKS_DEV_DIR" => dir }, hook, key, "run-a", "miette", "question", body)
  end

  def adapter
    require "hecks/agents/adapters/mail_spool"
    Hecks::Adapters::MailSpool.new(settings: { path: spool })
  end

  it "appends one JSON line for a send, in a file under the dev directory" do
    send_mail("how is it going")
    line = JSON.parse(File.read(spool))
    expect(line).to include("message" => "m1", "recipient" => "run-a", "kind" => "question")
  end

  it "refuses a body too long to append atomically, and writes nothing" do
    _out, _err, status = send_mail("x" * 5000)
    expect([status.success?, File.exist?(spool)]).to eq([false, false])
  end

  it "reads the first line past the cursor" do
    send_mail("one", key: "m1")
    send_mail("two", key: "m2")
    expect(adapter.read(pass: { value: "p" })).to include(message: { value: "m1" }, line: { value: 1 })
  end

  it "reads the next line once the cursor is acknowledged past the first" do
    send_mail("one", key: "m1")
    send_mail("two", key: "m2")
    adapter.acknowledge(pass: { value: "p" }, line: { value: 1 })
    expect(adapter.read(pass: { value: "p" })).to include(message: { value: "m2" })
  end

  it "answers an empty message when the spool holds no line past the cursor" do
    expect(adapter.read(pass: { value: "p" })).to include(message: { value: "" })
  end

  it "leaves a line the hook has not yet ended with a newline for the next read" do
    FileUtils.mkdir_p(File.dirname(spool))
    File.write(spool, "{\"message\":\"m9\"")
    expect(adapter.read(pass: { value: "p" })).to include(message: { value: "" })
  end

  def mark(kind, seat, position)
    Open3.capture3({ "HECKS_DEV_DIR" => dir }, File.join(root, ".claude/hooks/mail_mark.sh"), kind, seat, position)
  end

  it "appends a mark line that moves a seat's cursor, and boots nothing" do
    mark("advance", "run-a", "7")
    expect(JSON.parse(File.read(spool))).to eq("advance" => "run-a", "to" => 7)
  end

  it "reads a mark line as a line of its own, naming the seat and the position", :aggregate_failures do
    mark("open", "run-a", "7")
    answer = adapter.read(pass: { value: "p" })
    expect(answer).to include(open: { value: "run-a" }, to: { value: 7 }, line: { value: 1 })
    expect(answer[:advance]).to eq({ value: "" })
  end

  it "refuses a mark of a kind it does not know, and writes nothing", :aggregate_failures do
    _out, _err, status = mark("erase", "run-a", "7")
    expect([status.success?, File.exist?(spool)]).to eq([false, false])
  end
end
