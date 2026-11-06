# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/journal_store"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/mint_plan_shop"

# The mint plan and the real mint reach one decision on one store: the plan runs first, read-only,
# then the mint is asked for, and what the plan said would happen is what happens. It also writes
# nothing.
RSpec.describe "the mint plan agreeing with the mint", :io do
  include MintPlanShop

  MINT_PLAN_DB = "hecks_mint_plan_agreement_spec"

  scratch_postgres MINT_PLAN_DB, fenced: true

  let(:url) { FencedOwner.url(MINT_PLAN_DB) }
  let(:dir) { Dir.mktmpdir("mint-plan-agreement-") }
  let(:added) { source(note: true) }

  after { FileUtils.remove_entry(dir) }

  def era_count
    db = PG.connect(url)
    db.exec("SELECT count(*) AS n FROM hecks_eras")[0]["n"].to_i
  ensure
    db&.close
  end

  # What the mint did, asked for as the Maintenance mint asks: confirmed and would_mint.
  def mint(directory)
    held = Hecks::Adapters::JournalStore::HeldDomain.open(File.join(directory, "bluebook"))
    before = era_count
    Hecks::Adapters::PostgresRevision::LineageManager.check!(
      registry: held.registry, bluebook: held.bluebook, current_text: held.source_text, directory: held.directory,
      settings: held.settings.merge(mint_request: { confirm: true, verdict: "would_mint", watermark: 0 })
    )
    era_count > before ? "minted" : "nothing minted"
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  def agreement(current, edge: true, again: false)
    hold_then_change(dir, source, current, url: url)
    write_edge(dir, source, current) if edge
    write_edge(dir, source, current, name: "again") if again
    [plan_of(dir)[:plan], mint(dir)]
  end

  it "agrees on an additive move" do
    expect(agreement(added)).to eq(%w[would_mint minted])
  end

  it "agrees on a change no rule explains", :aggregate_failures do
    plan, minted = agreement(source(type: "String"))
    expect(plan).to eq("would_refuse")
    expect(minted).to include("cost")
  end

  it "agrees on two edges to one shape", :aggregate_failures do
    plan, minted = agreement(added, again: true)
    expect([plan, minted]).to match(["would_refuse", /2 translation edges/])
  end

  it "agrees on a change with no edge", :aggregate_failures do
    plan, minted = agreement(added, edge: false)
    expect([plan, minted]).to match(["would_refuse", /no translation edge covers it/])
  end

  it "agrees on a shape that did not move", :aggregate_failures do
    plan, minted = agreement(source, edge: false)
    expect([plan, minted]).to eq(["no_change", "nothing minted"])
  end

  it "writes nothing to the store", :aggregate_failures do
    hold_then_change(dir, source, added, url: url)
    write_edge(dir, source, added)
    before = database_state(url)
    plan_of(dir)
    expect(database_state(url)).to eq(before)
  end
end
