require "spec_helper"
require "fileutils"
require "json"
require "sqlite3"
require "tmpdir"
require "hecks/catcher/adapters/pattern_tally"

# The `Tally` port's adapter, against a Catcher store a spec builds in a scratch directory with the
# columns the runtime writes: value objects and lists as JSON text.
RSpec.describe Hecks::Adapters::PatternTally do
  let(:scratch) { Dir.mktmpdir("pattern-tally") }
  let(:path) { File.join(scratch, "catcher.db") }
  let(:wrapped) { described_class.new(settings: { path: path }).tally(run: { value: "d1" }) }
  let(:answer) { wrapped.transform_values { |held| held[:value] } }
  let(:nothing) do
    { subject: "", calls: 0, sessions: 0, success_rate: 0.0, proposal: "", proposed_kind: "",
      aggregate_name: "", raised_at: "" }
  end

  def call(subject, session, failed: false)
    { call_id: "#{subject}-#{session}-#{rand(1_000_000)}", source: "bash", tool: "git",
      subject: subject, succeeded: !failed, observed_in: session,
      observed_at: "2026-11-02T10:00:00Z" }
  end

  def insert(db, sql, rows) = rows.each { |row| db.execute(sql, row) }

  def store(sittings: [], audits: [])
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE observation (id TEXT PRIMARY KEY, sitting TEXT, calls TEXT)")
    db.execute("CREATE TABLE audit (id TEXT PRIMARY KEY, subject TEXT)")
    insert(db, "INSERT INTO observation VALUES (?, ?, ?)", sittings.each_with_index.map do |calls, i|
      ["s#{i}", JSON.generate(value: "s#{i}"), JSON.generate(calls)]
    end)
    insert(db, "INSERT INTO audit VALUES (?, ?)", audits.map { |name| [name, JSON.generate(value: name)] })
    db.close
  end

  def git_status_proposal
    ['aggregate "Git" do', '  command "Status" do', '    role "Operator"',
     '    goal "Run `git status`"', "  end", "end"].join("\n")
  end

  def fingerprint = [File.read(path), File.mtime(path), Dir.children(scratch).sort]

  after { FileUtils.rm_rf(scratch) }

  it "groups the calls of every sitting by subject and counts them" do
    store(sittings: [[call("git status", "a"), call("ls", "a")], [call("git status", "b")]])

    expect(answer).to include(subject: "git status", calls: 2)
  end

  it "counts the distinct sessions" do
    store(sittings: [[call("git status", "a"), call("git status", "a"), call("git status", "b")]])

    expect(answer[:sessions]).to eq(2)
  end

  it "rounds the success rate to two places" do
    store(sittings: [[call("ls", "a"), call("ls", "a", failed: true), call("ls", "b", failed: true)]])

    expect(answer[:success_rate]).to eq(0.33)
  end

  it "skips a subject that already has an audit" do
    store(sittings: [[call("git status", "a"), call("git status", "b"), call("ls", "a")]], audits: ["git status"])

    expect(answer[:subject]).to eq("ls")
  end

  it "picks the most sessions before the most calls" do
    store(sittings: [[call("ls", "a"), call("ls", "a"), call("ls", "a"), call("pwd", "a"),
                      call("pwd", "b")]])

    expect(answer[:subject]).to eq("pwd")
  end

  it "breaks a tie by the subject's name" do
    store(sittings: [[call("pwd", "a"), call("ls", "a")]])

    expect(answer[:subject]).to eq("ls")
  end

  it "proposes an aggregate named for the subject's first word" do
    store(sittings: [[call("git status", "a")]])

    expect(answer).to include(proposed_kind: "aggregate", aggregate_name: "Git")
  end

  it "proposes a command for the remaining words" do
    store(sittings: [[call("git status", "a")]])

    expect(answer[:proposal]).to eq(git_status_proposal)
  end

  it "names the command for a one-word subject after the subject" do
    store(sittings: [[call("ls", "a")]])

    expect(answer[:proposal]).to include('aggregate "Ls" do', 'command "Ls" do')
  end

  it "answers the instant it was raised, to the second in UTC" do
    store(sittings: [[call("ls", "a")]])

    expect(answer[:raised_at]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
  end

  it "wraps every answer in a value" do
    store(sittings: [[call("ls", "a")]])

    expect(wrapped[:calls]).to eq(value: 1)
  end

  it "answers no calls and empty text when no call was kept" do
    store

    expect(answer).to eq(nothing)
  end

  it "answers no calls and empty text when every subject has an audit" do
    store(sittings: [[call("ls", "a")]], audits: ["ls"])

    expect(answer).to eq(nothing)
  end

  it "answers no calls and empty text when there is no store" do
    expect(answer).to eq(nothing)
  end

  it "does not create the store" do
    answer

    expect(File.exist?(path)).to be(false)
  end

  it "wraps the empty answer in a value too" do
    expect(wrapped[:success_rate]).to eq(value: 0.0)
  end

  it "does not modify the store or create files beside it" do
    store(sittings: [[call("ls", "a")]])
    before = fingerprint
    answer

    expect(fingerprint).to eq(before)
  end

  it "defaults the store to the Catcher world's file under the home directory" do
    expect(described_class::DEFAULT_PATH).to eq("~/.claude/hecks-dev/catcher.db")
  end
end
