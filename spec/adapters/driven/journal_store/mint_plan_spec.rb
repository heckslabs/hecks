# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/journal_store"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/mint_plan_shop"

# The mint plan runs every guard the mint runs, read-only, on a scratch PostgresRevisions database.
RSpec.describe "the mint plan", :io do
  include MintPlanShop

  PLAN_DB = "hecks_mint_plan_spec"

  scratch_postgres PLAN_DB, fenced: true

  let(:url) { FencedOwner.url(PLAN_DB) }
  let(:dir) { Dir.mktmpdir("mint-plan-") }
  let(:first) { source }
  let(:added) { source(note: true) }

  after { FileUtils.remove_entry(dir) }

  def prepare(current, edge: true)
    hold_then_change(dir, first, current, url: url)
    write_edge(dir, first, current) if edge
  end

  def statuses(plan) = plan[:guards].to_h { |entry| [entry[:guard], entry[:status]] }

  it "passes every guard for an additive move held to current", :aggregate_failures do
    prepare(added)
    plan = plan_of(dir)
    expect(plan[:plan]).to eq("would_mint")
    expect(statuses(plan).values_at("edge", "coverage", "audit")).to eq(%w[pass pass pass])
  end

  it "names the command that mints, at the live watermark", :aggregate_failures do
    prepare(added)
    command = plan_of(dir)[:command]
    expect(command).to include("Maintenance.mint_era!", "era=2", "watermark=0", "domain=Ledger")
  end

  it "passes a reference held as its string and declared as the object", :aggregate_failures do
    held = source(reference: true)
    hold_then_change(dir, held, source(reference: true, note: true), url: url)
    write_edge(dir, held, source(reference: true, note: true))
    expect(statuses(plan_of(dir))).to include("coverage" => "pass")
  end

  it "refuses a genuine retype no rule explains, with the coverage message", :aggregate_failures do
    prepare(source(type: "String"))
    plan = plan_of(dir)
    expect(plan[:plan]).to eq("would_refuse")
    expect(guard(plan, "coverage")[:detail]).to include("cost")
  end

  it "refuses two edges that lead to the same shape", :aggregate_failures do
    prepare(added)
    write_edge(dir, first, added, name: "again")
    expect(guard(plan_of(dir), "edge")).to include(status: "refuse", detail: /2 translation edges/)
  end

  it "refuses a change with no edge and no recorded move", :aggregate_failures do
    prepare(added, edge: false)
    expect([plan_of(dir)[:plan], guard(plan_of(dir), "edge")[:status]]).to eq(%w[would_refuse refuse])
  end

  it "answers no_change when the shape did not move", :aggregate_failures do
    prepare(first, edge: false)
    expect(plan_of(dir)).to include(plan: "no_change", command: nil)
  end

  it "says no mint is needed for a disposable ledger", :aggregate_failures do
    write_domain(dir, first, url: url, world_lines: "disposable_ledger true")
    expect(plan_of(dir)).to include(plan: "disposable")
    expect(guard(plan_of(dir), "eras")[:detail]).to include("disposable: no mint needed")
  end

  it "reports a quiesce marker", :aggregate_failures do
    prepare(added)
    File.write(File.join(dir, "quiesce"), "")
    plan = Hecks::Adapters::JournalStore::Readings::MintPlan::Plan.new(File.join(dir, "bluebook"), dev_dir: dir).to_h
    expect(guard(plan, "quiesce")[:detail]).to include("quiesced")
  end
end
