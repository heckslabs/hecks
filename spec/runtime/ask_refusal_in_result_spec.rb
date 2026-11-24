require "spec_helper"
require "securerandom"

# A port adapter's refusal of a policy's ask is a refused reaction of the dispatch that caused it:
# the result names it, `--wait` fails on it, and a policy that answers the refusal excuses it.
# The Tickets domain's `ComposeNote` ask has no policy on its refusal (`NoteRefused`); its
# `OpenIssue` ask has one (`GitHubRefused`). Adapters are stood in for, so nothing outside runs.
RSpec.describe "an ask a port adapter refused" do
  let(:hecks) { boot_hecks_in_memory }
  let(:key)   { "ask-#{SecureRandom.hex(4)}" }

  # Answers every ask with an adapter that refuses it, as a failing outside world does.
  def refusing(_port, _asked)
    Class.new { def method_missing(*) = raise(RuntimeError, "no word on the page") }.new
  end

  def dispatch(verb, **facts)
    Hecks::Runtime::AdapterLookup.standing_in(method(:refusing)) { hecks.dispatch_flat(verb, **facts) }
  end

  def planned
    dispatch("Tickets::Work.Plan", work: { value: key }, title: { value: key }, detail: { value: "d" }, area: [])
  end

  def noted
    planned
    dispatch("Tickets::Work.Note", work: { value: key }, note: { value: "n" }, dated: { value: "2026-11-23" })
  end

  it "is named by the result when no policy answers it", :aggregate_failures do
    result = noted

    expect(result.refused_reactions.map { |row| row[:reason] }).to include(a_string_matching(/no word on the page/))
    expect(result.blocking_reactions.map { |row| row[:policy] }).to include("ComposeNote")
  end

  it "does not block the run when a policy answers the refusal", :aggregate_failures do
    ENV["HECKS_FINDINGS_REPO"] = nil
    result = dispatch("Tickets::Finding.ReportFailedRun", finding: key, title: "t", body: "b")

    expect(result.refused_reactions.map { |row| row[:policy] }).to include("OpenIssue")
    expect(result.blocking_reactions.map { |row| row[:policy] }).not_to include("OpenIssue")
  end
end
