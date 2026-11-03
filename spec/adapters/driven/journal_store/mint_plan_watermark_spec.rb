# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/journal_store"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/mint_plan_shop"

# The watermark rule of the mint plan: the ledger may move above a rehearsal's watermark only by the
# run's own Maintenance record, and a rehearsal the ledger moved past is reported stale.
RSpec.describe "the mint plan's watermark and rehearsal ref", :io do
  include MintPlanShop

  WATERMARK_DB = "hecks_mint_plan_watermark_spec"

  scratch_postgres WATERMARK_DB, fenced: true

  let(:url) { FencedOwner.url(WATERMARK_DB) }
  let(:dir) { Dir.mktmpdir("mint-plan-watermark-") }
  let(:added) { source(note: true) }

  before do
    hold_then_change(dir, source, added, url: url)
    write_edge(dir, source, added)
  end

  after { FileUtils.remove_entry(dir) }

  def plan_for(**) = plan_of(dir, rehearsal_ref: "run-1", rehearsal_watermark: 0, rehearsal_verdict: "would_mint", **)

  def rehearsed = guard(plan_for, "rehearsal_ref")

  it "names the live watermark the mint call takes" do
    append_row(url, "acct", "a-1")
    expect(guard(plan_of(dir), "watermark")[:detail]).to include("watermark=1")
  end

  it "passes when only the run's own record moved the ledger" do
    append_row(url, "maintenance", "run-1")
    expect(rehearsed).to include(status: "pass")
  end

  it "refuses when a foreign row moved the ledger", :aggregate_failures do
    append_row(url, "maintenance", "run-1")
    append_row(url, "acct", "a-1")
    expect(rehearsed).to include(status: "refuse", detail: /moved from 0 to 2/)
  end

  it "refuses a rehearsal that did not say would_mint" do
    plan = plan_of(dir, rehearsal_ref: "run-1", rehearsal_watermark: 0, rehearsal_verdict: "would_refuse")
    expect(guard(plan, "rehearsal_ref")).to include(status: "refuse", detail: /not would_mint/)
  end

  it "says a rehearsal it holds no record of is unknown" do
    expect(guard(plan_of(dir, rehearsal_ref: "run-9"), "rehearsal_ref")).to include(status: "refuse", detail: /no record/)
  end

  it "makes the whole plan refuse when the rehearsal is stale" do
    append_row(url, "acct", "a-1")
    expect(plan_for).to include(plan: "would_refuse")
  end
end
