require "spec_helper"
require "json"
require "hecks/hecks/adapters/git_rehearsal"
require "hecks/quality_control/adapters/push_due_reader"

# The QA tick's push check: one `push-due` Work item, filed when a push of local main is due beyond
# the thresholds, revised while it stays due and finished when it is not. The rehearsal adapter's
# `Due` is stubbed with the line it answers, and the Hecks domain boots in Memory, so no git or
# ledger is read.
RSpec.describe "the push nudge" do
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false) }
  let(:rehearsal) { instance_double(Hecks::Adapters::GitRehearsal) }
  let(:counter) { [0] }

  before { allow(Hecks::Adapters::GitRehearsal).to receive(:new).and_return(rehearsal) }

  def cli(context, *argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: [context, *argv])
    out
  end

  def due_line(text) = allow(rehearsal).to receive(:due).and_return({ text: text })

  def check = cli("quality_control", "push_nudge.check!", "nudge.value=check-#{counter[0] += 1}")

  def rows = JSON.parse(cli("tickets", "work.undone")).select { |row| row["work"] == "push-due" }

  def ahead(count, hours: 1.0, rehearsed: "green on abc1234 (the current main)")
    due_line("push due: yes; #{count} commit(s) ahead of origin/main; oldest unpushed #{hours} hours old; " \
             "last rehearsal: #{rehearsed}")
  end

  it "files one row when the commits ahead pass the threshold", :aggregate_failures do
    ahead(27)
    check

    expect(rows.size).to eq(1)
    expect(rows.first["detail"]).to include("27 commit(s) ahead", "15 commits", "6.0 hours", "urgent at 40")
  end

  it "files one row when the oldest unpushed commit is old enough" do
    ahead(3, hours: 7.5)
    check

    expect(rows.size).to eq(1)
  end

  it "files nothing while the push is under every threshold" do
    ahead(3, hours: 2.0)
    check

    expect(rows).to be_empty
  end

  it "updates the open row on a second check instead of filing another", :aggregate_failures do
    ahead(27)
    check
    ahead(31)
    check

    expect(rows.map { |row| row["detail"] }).to match([include("31 commit(s) ahead")])
  end

  it "finishes the row once the push is no longer due" do
    ahead(27)
    check
    due_line("push due: no; main is level with origin/main; last rehearsal: none yet")
    check

    expect(rows).to be_empty
  end

  def titles = rows.map { |row| row["title"] }

  it "titles the row by size class" do
    ahead(16)
    check

    expect(titles).to eq(["a push of main is due, 16 commits"])
  end

  it "revises the title as the push grows to urgent" do
    ahead(16)
    check
    ahead(45)
    check

    expect(titles).to eq(["URGENT: a push of main is due, 45 commits"])
  end

  it "files the row for a red last rehearsal on the current main even under the numbers" do
    ahead(2, hours: 0.5, rehearsed: "red (quick) on abc1234 (the current main)")
    check

    expect(rows.size).to eq(1)
  end

  it "does not file for a red rehearsal of a main that has moved" do
    ahead(2, hours: 0.5, rehearsed: "red (quick) on abc1234 (main has moved since)")
    check

    expect(rows).to be_empty
  end

  it "reads the thresholds from the world and falls back to the defaults", :aggregate_failures do
    world = instance_double(Hecks::Bluebook::World, for_verb: { adapter: "PushDueReader", commits: 5, hours: 2 })
    registry = instance_double(Hecks::Runtime::Registry, world: world)

    expect(Hecks::Adapters::PushDueReader.thresholds(registry)).to eq({ commits: 5, hours: 2.0, urgent_commits: 40 })
    expect(Hecks::Adapters::PushDueReader.thresholds(nil)).to eq({ commits: 15, hours: 6.0, urgent_commits: 40 })
  end
end
