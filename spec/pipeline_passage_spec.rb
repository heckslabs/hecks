# frozen_string_literal: true

require "spec_helper"
require "json"

# The Pipeline bluebook through the booted Hecks domain, in Memory: a planned Work item opens a
# passage, starting the Work item dispatches it, and the stages after that move in order and refuse
# to
# skip. The landing, push, flag, promotion and release policies are driven by events other
# domains emit from real git and GitHub, so here their commands are sent directly.
RSpec.describe "Pipeline passages" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def run(*argv) = JSON.parse(launch(*argv, "--wait").first)

  def plan(work) = run("tickets", "Work.plan!", "work.value=#{work}", "title.value=Title #{work}")

  def start(work, session = "s1")
    run("tickets", "Work.start!", "to=#{work}", "claimed_by.value=#{session}", "claimed_at.value=2026-11-02T10:00:00Z")
  end

  def yield_row(work) = run("tickets", "Work.yield!", "to=#{work}", "reason.value=area overlaps")

  def rows(query) = JSON.parse(launch("pipeline", "Passage.#{query}").first)

  def passage(change) = rows("in_flight").find { |row| row["change"] == change }

  def advance(change, verb, *args) = run("pipeline", "Passage.#{verb}!", "to=#{change}", *args)

  def refusal(change, verb, *args) = launch("pipeline", "Passage.#{verb}!", "to=#{change}", *args, "--wait").join

  it "opens a passage at planned when a Work item is planned" do
    plan("p-plan")
    expect(passage("p-plan")).to include("stage" => "planned")
  end

  it "dispatches the passage to the session that started the Work item", :aggregate_failures do
    plan("p-start")
    start("p-start")
    expect(passage("p-start")).to include("stage" => "dispatched", "session" => "s1")
  end

  it "dispatches a yielded Work item again to the session that starts it next", :aggregate_failures do
    plan("p-again")
    start("p-again")
    yield_row("p-again")
    start("p-again", "s2")
    expect(passage("p-again")).to include("stage" => "dispatched", "session" => "s2")
  end

  it "moves through landed, pushed, verified, promoted and released in order", :aggregate_failures do
    plan("p-walk")
    advance("p-walk", "land")
    advance("p-walk", "push", "pushed.value=abc1234")
    %w[verify promote release].each { |verb| advance("p-walk", verb) }
    expect(passage("p-walk")).to be_nil
  end

  it "can be held by a red flag while pushed and verified from held", :aggregate_failures do
    plan("p-hold")
    advance("p-hold", "land")
    advance("p-hold", "push", "pushed.value=abc1234")
    expect(advance("p-hold", "hold", "flag.value=flag-1").dig("state", "stage")).to eq("held")
    expect(advance("p-hold", "verify").dig("state", "stage")).to eq("verified")
  end

  it "refuses to push a passage that has not landed" do
    plan("p-skip")
    expect(refusal("p-skip", "push", "pushed.value=abc1234")).to include("lifecycle_refused", "only from \"landed\"")
  end

  it "lists a stalled passage with its reason" do
    plan("p-stall")
    advance("p-stall", "stall", "stalled.value=no session for 3 h")
    expect(rows("stalled").map { |row| row["change"] }).to include("p-stall")
  end

  it "clears the stalled mark when the passage moves on" do
    plan("p-moved")
    advance("p-moved", "stall", "stalled.value=no session for 3 h")
    advance("p-moved", "land")
    expect(passage("p-moved")).to include("stalled" => "", "stage" => "landed")
  end
end
