require "spec_helper"

# A planned or rescoped work item's area is read against this checkout: a word that names no path
# and no declaration holds the item, still planned and in the undone list, naming the word. Each
# example boots its own Memory domain, and the paths are this repository's own.
require_relative "support/new_work_started"

RSpec.describe "Work area names" do
  include_context "with new work started"

  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def plan(key, *area)
    cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}", *area.map { |word| "area.value=#{word}" })
    row(key)
  end

  def records
    aggregate = hecks.registry.bluebook("Tickets").aggregate("Work")
    hecks.registry.repository("Tickets", aggregate).all
  end

  def row(key)
    work = records.find { |item| field(item, :work) == key }
    { "status" => field(work, :status), "held" => field(work, :held_reason), "area" => field(work, :area) }
  end

  def field(record, name) = Hecks::Adapters::StartedWork.value(record, name).to_s

  it "keeps a planned item whose area names a directory, a new file and a glob" do
    work = plan("names/a", "lib/hecks/tickets", "spec/not_yet_written_spec.rb", "lib/**/area_overlap.rb")

    expect(work["status"]).to eq("planned")
  end

  it "keeps a planned item whose sections are declarations of the bluebook" do
    work = plan("names/b", "lib/hecks/tickets/bluebook/tickets.bluebook#Work,CheckAreaWhenStarted")

    expect(work["status"]).to eq("planned")
  end

  it "holds a planned item whose area names a mistyped directory, naming the word", :aggregate_failures do
    work = plan("names/c", "lib/hecks/tickets", "lib/hecks/tickts")

    expect(work["status"]).to eq("planned")
    expect(work["held"]).to include("names/c", "lib/hecks/tickts")
  end

  it "holds a planned item whose glob matches nothing or whose section is not declared", :aggregate_failures do
    work = plan("names/d", "lib/**/no_such_file_anywhere.rb", "lib/hecks/tickets/bluebook/tickets.bluebook#Nope")

    expect(work["held"]).to include("no_such_file_anywhere.rb", "tickets.bluebook#Nope")
    expect(work["held"]).not_to include("lib/hecks/tickets,")
  end

  it "holds a planned item rescoped to a word that names nothing", :aggregate_failures do
    plan("names/e", "lib/hecks/tickets")
    cli("work.rescope!", "to=names/e", "area.value=lib/no/such/dir")

    expect(row("names/e")["status"]).to eq("planned")
    expect(row("names/e")["held"]).to include("lib/no/such/dir")
  end

  it "keeps a held item among the work items, planned and never dropped", :aggregate_failures do
    plan("names/i", "lib/hecks/tickts")

    expect(records.map { |item| field(item, :work) }).to include("names/i")
    expect(row("names/i")["status"]).to eq("planned")
  end

  it "shows the refusal in the answer to the plan" do
    out = cli("work.plan!", "work.value=names/j", "title.value=Step", "area.value=lib/hecks/tickts")

    expect(out).to include("lib/hecks/tickts")
  end

  it "refuses to start a held item" do
    plan("names/k", "lib/hecks/tickts")
    cli("work.start!", "to=names/k", "claimed_by.value=s", "claimed_at.value=2026-10-31T09:00:00Z")
    expect(row("names/k")["status"]).to eq("planned")
  end

  it "releases the hold when the item is rescoped to an area that names the checkout" do
    plan("names/l", "lib/hecks/tickts")
    cli("work.rescope!", "to=names/l", "area.value=lib/hecks/tickets")
    expect(row("names/l")["held"]).to eq("")
  end

  it "keeps a started item rescoped to a word that names nothing: its coder holds it", :aggregate_failures do
    plan("names/f", "lib/hecks/tickets")
    cli("work.start!", "to=names/f", "claimed_by.value=s", "claimed_at.value=2026-10-31T09:00:00Z")
    cli("work.rescope!", "to=names/f", "area.value=lib/no/such/dir")

    expect(row("names/f")["status"]).to eq("started")
    expect(row("names/f")["area"]).to include("lib/no/such/dir")
  end

  # A new directory is named by the directory that holds it, a new aggregate by its file alone.
  it "holds a planned item naming a new directory or a new aggregate's section" do
    work = plan("names/h", "lib/hecks/brand_new/thing.rb", "lib/hecks/tickets/bluebook/tickets.bluebook#NewAgg")

    expect(work["held"]).to include("lib/hecks/brand_new/thing.rb", "tickets.bluebook#NewAgg")
  end
end
