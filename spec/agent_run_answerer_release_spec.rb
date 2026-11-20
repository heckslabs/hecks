require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/question_answerer_helpers"

# An answerer that fails, could not start, or ends without answering releases the question it was
# seated for, which frees its seat; an answered or escalated question is not released again. The
# answerer reads its own run and the question it serves in two small reads.
RSpec.describe "an answerer that ends without answering" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include QuestionAnswererHelpers

  let(:woken) { [] }

  prepend_before { @hecks = boot_hecks_in_memory }
  before { fake_runner(woken) }

  def answerer_reads(run, state)
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def question_of(run) = JSON.parse(launch("Question.of_run", "run=#{run}").first.to_s[/\[.*\]/m] || "[]").first.to_h

  def status_of(run) = question_of(run)["status"]

  it "releases the question of an answerer that failed, its seat freed", :aggregate_failures do
    blocked_on("r-failed", "[choose] A or B?")
    answerer_reads(answerers("r-failed").first["run"], "failed")
    expect(status_of("r-failed")).to eq("released")
    expect(desk["seated"]).to eq(0)
  end

  it "releases the question of an answerer that ended without answering", :aggregate_failures do
    blocked_on("r-ended", "[choose] A or B?")
    answerer_reads(answerers("r-ended").first["run"], "done")
    expect(status_of("r-ended")).to eq("released")
    expect(desk["seated"]).to eq(0)
  end

  it "releases the question of an answerer that closed with its word but never answered" do
    blocked_on("r-closed", "[choose] A or B?")
    answerer_closes(answerers("r-closed").first["run"], "Told it to take A. answered")
    expect(status_of("r-closed")).to eq("released")
  end

  it "releases nothing when the answerer answered before it ended", :aggregate_failures do
    blocked_on("r-answered", "[choose] A or B?")
    run = answerers("r-answered").first["run"]
    answer("r-answered") && answerer_reads(run, "done")
    expect(status_of("r-answered")).to eq("closed")
    expect(desk["seated"]).to eq(0)
  end

  it "keeps the question of a blocked answerer escalated, its seat freed once", :aggregate_failures do
    answerer_blocks("r-escalated", "cannot answer: the owner's call")
    expect(status_of("r-escalated")).to eq("escalated")
    expect(desk["seated"]).to eq(0)
  end

  it "lists the answerer with the blocked run as its work" do
    blocked_on("r-reads", "[choose] A or B?")
    rows = JSON.parse(launch("agent_run.answering").first.to_s[/\[.*\]/m] || "[]")
    expect(rows.map { |row| row["work"] }).to eq(["r-reads"])
  end

  it "reads the question a blocked run asks by its run" do
    blocked_on("r-text", "[choose] A or B?")
    expect(question_of("r-text")["text"]).to eq("[choose] A or B?")
  end
end
