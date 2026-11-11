require "spec_helper"

# ADR 0204: an epic's status comes from its members. The last open member closing completes it, a
# member returning reopens it, an epic with no members cannot complete, and only an open work item
# joins an epic.
RSpec.describe "the Tickets Epic" do
  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def epic(key = "e1")
    cli("epic.open!", "epic.value=#{key}", "title.value=Epic #{key}", "outcome.value=It is carried out")
  end

  def member(key, epic: "e1")
    cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}")
    cli("work.assign!", "to=#{key}", "epic=#{epic}")
  end

  def finish(*keys) = keys.each { |key| cli("work.finish!", "to=#{key}") }

  def stored(name)
    aggregate = hecks.registry.bluebook("Tickets").aggregates.find { |declared| declared.hecks_name == name }
    hecks.registry.repository("Tickets", aggregate).all
  end

  def plain(value) = value.respond_to?(:value) ? value.value : value

  def status_of(key = "e1") = plain(stored("Epic").find { |row| plain(row.epic) == key }.status)

  def work_row(key) = stored("Work").find { |row| plain(row.work) == key }

  def complete(members, open_members)
    cli("epic.complete!", "to=e1", "members.value=#{members}", "open_members.value=#{open_members}")
  end

  it "opens an epic with its outcome" do
    epic

    expect(status_of).to eq("open")
  end

  it "stays open while a member is open" do
    epic
    %w[m1 m2].each { |key| member(key) }
    finish("m1")

    expect(status_of).to eq("open")
  end

  it "completes when its last open member finishes or is dropped" do
    epic
    %w[m1 m2].each { |key| member(key) }
    finish("m1")
    cli("work.drop!", "to=m2", "reason.value=not needed")

    expect(status_of).to eq("complete")
  end

  it "reopens when a member returns" do
    epic
    member("m1")
    finish("m1")
    cli("work.reopen!", "to=m1", "title.value=Again")

    expect(status_of).to eq("open")
  end

  it "reopens when an open member joins a complete epic" do
    epic
    member("m1")
    finish("m1")
    member("m2")

    expect(status_of).to eq("open")
  end

  it "refuses to complete an epic with no member", :aggregate_failures do
    epic

    expect(complete(0, 0)).to include("an epic with no member does not complete")
    expect(status_of).to eq("open")
  end

  it "refuses to complete an epic with an open member", :aggregate_failures do
    epic

    expect(complete(2, 1)).to include("a planned or started member does not complete")
    expect(status_of).to eq("open")
  end

  it "refuses to assign a finished work item" do
    epic
    cli("work.plan!", "work.value=done1", "title.value=Done")
    finish("done1")

    expect(cli("work.assign!", "to=done1", "epic=e1")).to include("a done work item joins no epic")
  end

  it "refuses to assign a dropped work item" do
    epic
    cli("work.plan!", "work.value=gone1", "title.value=Gone")
    cli("work.drop!", "to=gone1", "reason.value=not needed")

    expect(cli("work.assign!", "to=gone1", "epic=e1")).to include("a dropped work item joins no epic")
  end

  it "reads a work item with no epic, as every row from before epics is", :aggregate_failures do
    cli("work.plan!", "work.value=old1", "title.value=Old")
    finish("old1")

    expect(plain(work_row("old1").status)).to eq("done")
    expect(plain(work_row("old1").epic).to_s).to eq("")
  end

  it "answers the undone members in plan order" do
    epic
    %w[m1 m2 m3].each { |key| member(key) }
    finish("m1")

    expect(JSON.parse(cli("work.undone_in_epic", "epic=e1")).map { |work| work["work"] }).to eq(%w[m2 m3])
  end

  it "answers the progress with the next planned member" do
    epic
    %w[m1 m2 m3].each { |key| member(key) }
    finish("m1")

    expect(cli("work.epic_progress", "epic=e1")).to include("done 1, dropped 0, open 2", "next: m2")
  end
end
