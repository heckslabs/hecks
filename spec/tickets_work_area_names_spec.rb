require "spec_helper"

# A planned or rescoped work item's area is read against this checkout: a word that names no path
# and no declaration sets a planned item aside, naming the word. Each example boots its own Memory
# domain, and the paths are this repository's own.
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

  def row(key)
    aggregate = hecks.registry.bluebook("Tickets").aggregate("Work")
    work = hecks.registry.repository("Tickets", aggregate).all.find { |item| field(item, :work) == key }
    { "status" => field(work, :status), "reason" => field(work, :reason), "area" => field(work, :area) }
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

  it "drops a planned item whose area names a mistyped directory, naming the word", :aggregate_failures do
    work = plan("names/c", "lib/hecks/tickets", "lib/hecks/tickts")

    expect(work["status"]).to eq("dropped")
    expect(work["reason"]).to include("names/c", "lib/hecks/tickts")
  end

  it "drops a planned item whose glob matches nothing or whose section is not declared", :aggregate_failures do
    work = plan("names/d", "lib/**/no_such_file_anywhere.rb", "lib/hecks/tickets/bluebook/tickets.bluebook#Nope")

    expect(work["reason"]).to include("no_such_file_anywhere.rb", "tickets.bluebook#Nope")
    expect(work["reason"]).not_to include("lib/hecks/tickets,")
  end

  it "drops a planned item rescoped to a word that names nothing", :aggregate_failures do
    plan("names/e", "lib/hecks/tickets")
    cli("work.rescope!", "to=names/e", "area.value=lib/no/such/dir")

    expect(row("names/e")["status"]).to eq("dropped")
    expect(row("names/e")["reason"]).to include("lib/no/such/dir")
  end

  it "keeps a started item rescoped to a word that names nothing: its coder holds it" do
    plan("names/f", "lib/hecks/tickets")
    cli("work.start!", "to=names/f", "claimed_by.value=s", "claimed_at.value=2026-10-31T09:00:00Z")
    cli("work.rescope!", "to=names/f", "area.value=lib/no/such/dir")
    expect(row("names/f")["status"]).to eq("started")
  end

  # The refusal is Misname's given, so the rescope itself stands.
  it "rescopes a started item to a word that names nothing" do
    plan("names/g", "lib/hecks/tickets")
    cli("work.start!", "to=names/g", "claimed_by.value=s", "claimed_at.value=2026-10-31T09:00:00Z")
    cli("work.rescope!", "to=names/g", "area.value=lib/no/such/dir")
    expect(row("names/g")["area"]).to include("lib/no/such/dir")
  end

  # A new directory is named by the directory that holds it, a new aggregate by its file alone.
  it "drops a planned item naming a new directory or a new aggregate's section", :aggregate_failures do
    work = plan("names/h", "lib/hecks/brand_new/thing.rb", "lib/hecks/tickets/bluebook/tickets.bluebook#NewAgg")

    expect(work["reason"]).to include("lib/hecks/brand_new/thing.rb", "tickets.bluebook#NewAgg")
  end
end
