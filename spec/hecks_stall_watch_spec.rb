require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# A stall is an opening event of a `StallKind` row whose closing event has not come within the
# row's minutes. A look (`StallWatch.Detect`) reads a throwaway tap and files each stall once, as a
# `Stall` and a Tickets work item of the same key, which the dispatch fill starts after red.
RSpec.describe "StallWatch" do
  include_context "with a stall watch tap"

  it "sees every opening line no closing line followed, with how long it waited", :aggregate_failures do
    write_tap
    rows = watching.unclosed(run: { value: "look-1" })

    expect(rows.map { |row| row[:stall] }).to eq(%w[stall-plan-review-late stall-plan-review-young])
    expect(rows.first).to include(id: "look-1", waited: 30, minutes: 20, fixer: "orchestrator")
  end

  it "files a stall past its minutes as one Stall and one work item of the same key", :aggregate_failures do
    write_tap
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-plan-review-late])
    expect(keys("Tickets", "Work", :work)).to eq(%w[stall-plan-review-late])
  end

  it "files a red train pull request nobody reran in 10 minutes, naming it" do
    write_train_pr_tap
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-train-pr-red-silent-pr])
  end

  it "files a stall once, however many looks see it" do
    write_tap
    detect("look-1")
    detect("look-2")

    expect(registry.event_log.map(&:name).count("StallFiled")).to eq(1)
  end

  it "files a blocked run nobody answered in 15 minutes, naming the run", :aggregate_failures do
    write_blocked_tap
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-agent-run-blocked-stuck])
    expect(keys("Tickets", "Work", :work)).to eq(%w[stall-agent-run-blocked-stuck])
  end

  describe "a coder blocked on a [choose] question" do
    def write_asked(*closing)
      rows = [["SessionBlocked", "asker", 20], *closing]
      lines = rows.each_with_index.map { |(event, id, ago), seq| line(seq + 1, event, id, ago).merge(aggregate: "Hecks::AgentRun") }
      File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
    end

    it "stays a stall until the answer is requested" do
      write_asked
      detect("look-1")

      expect(keys("Hecks", "Stall", :stall)).to eq(%w[stall-agent-run-blocked-asker])
    end

    it "is closed by AnswerRequested, before the session reports being answered" do
      write_asked(["AnswerRequested", "asker", 18])
      detect("look-1")

      expect(keys("Hecks", "Stall", :stall)).to be_empty
    end

    it "carries a move that answers from the brief or plans a work item, never asking the owner", :aggregate_failures do
      write_asked
      detect("look-1")

      expect(keys("Tickets", "Work", :detail).first)
        .to include("[choose]", "Work.rescope!", "Work.plan!", "Never ask the owner")
    end
  end

  describe "the move of each kind" do
    let(:opening) do
      { "plan-review"       => ["Agents::PlanReview", "PlanReviewRequested"],
        "agent-run-start"   => ["Hecks::AgentRun", "AgentRunRequested"],
        "agent-run-session" => ["Hecks::AgentRun", "AgentRunStarted"],
        "agent-run-blocked" => ["Hecks::AgentRun", "SessionBlocked"] }
    end

    def write_opening(kind)
      aggregate, event = opening.fetch(kind)
      File.write(tap, "#{JSON.generate(line(1, event, "subject", 300).merge(aggregate: aggregate))}\n")
    end

    def work_detail = keys("Tickets", "Work", :detail).first

    %w[plan-review agent-run-start agent-run-session agent-run-blocked].each do |kind|
      it "gives the #{kind} work item the move of its row, once, never stopping a session", :aggregate_failures do
        write_opening(kind)
        2.times { |look| detect("look-#{look}") }

        expect(keys("Tickets", "Work", :work)).to eq(["stall-#{kind}-subject"])
        expect(work_detail).to include("Move: ", "Never stop or kill a session.")
      end
    end

    it "names only commands the orchestrator may run", :aggregate_failures do
      write_opening("agent-run-session")
      detect("look-1")

      expect(work_detail).to include("AgentRun.check!", "AgentRun.answer!", "Work.yield!")
    end
  end

  it "looks for stalls on every beat of the clock" do
    File.write(tap, "")
    with_tap { dispatch("Hecks::Heartbeat.Beat", beat: { value: "beat-1" }) }

    expect(registry.event_log.map(&:name)).to include("StallDetectRequested")
  end

  it "starts a filed stall after a red work item and before every other one" do
    %w[stall-train-events now-item].each { |work| plan(work, "now") }
    %w[stall-plan-review-late red-spec].each { |work| plan(work) }

    expect(Hecks::Adapters::Dispatching::WorkItems.new(registry).planned.map(&:key))
      .to eq(%w[red-spec stall-plan-review-late now-item stall-train-events])
  end
end
