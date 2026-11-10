# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require "hecks/pipeline_board/adapters/pipeline_web/actions"

# The board's rules live in pipeline_board.bluebook: `Verdict` rows say which state a stage or a
# tile is in, `Setting` rows hold the numbers, `Finding` rows name what the fan-out flags and
# `ActionRule` rows say what each page step needs and runs. These examples read the rows through
# the adapters' one reader and fail if an adapter starts deciding on its own again.
RSpec.describe Hecks::Adapters::PipelineBoard::Rules do
  let(:board) { Hecks::Adapters::PipelineBoard }
  let(:adapters) { File.expand_path("../lib/hecks/pipeline_board/adapters", __dir__) }

  def verdict(stage, measures, limits = {}) = described_class.verdict(stage, measures, limits)

  it "declares every row table the adapters read", :aggregate_failures do
    described_class::TABLES.each { |name| expect(described_class.rows(name)).not_to be_empty }
  end

  describe "the strip" do
    it "marks local main, the train, the promotion and the release when they lag", :aggregate_failures do
      expect(verdict("Local main", { ahead: 1 })).to eq("attention")
      expect(verdict("Local main", { ahead: 0 })).to eq("ok")
      expect(verdict("Train", { not_pushed: 1 })).to eq("attention")
      expect(verdict("Promote", { behind: 3 })).to eq("attention")
      expect(verdict("Release", { unpublished: 1 })).to eq("attention")
    end

    it "gives CI working while it runs, failed when it did not succeed, else ok", :aggregate_failures do
      expect(verdict("CI", { running: 1, unsuccessful: 1 })).to eq("working")
      expect(verdict("CI", { running: 0, unsuccessful: 1 })).to eq("failed")
      expect(verdict("CI", { running: 0, unsuccessful: 0 })).to eq("ok")
    end

    it "puts attention over working for sessions, and working over ok", :aggregate_failures do
      expect(verdict("Sessions", { busy: 2, blocked: 1 })).to eq("attention")
      expect(verdict("Sessions", { busy: 2, blocked: 0 })).to eq("working")
      expect(verdict("Sessions", { busy: 0, blocked: 0 })).to eq("ok")
    end

    it "always fails the red flag" do
      expect(verdict("Red flag", {})).to eq("failed")
    end
  end

  describe "the tiles" do
    let(:goal) { { wall_goal_minutes: 3, success_good: 80, success_fair: 50 } }

    it "bands the success rate by the good and fair settings", :aggregate_failures do
      expect(verdict("CI success", { value: 80 }, goal)).to eq("ok")
      expect(verdict("CI success", { value: 79 }, goal)).to eq("attention")
      expect(verdict("CI success", { value: 49 }, goal)).to eq("failed")
      expect(verdict("CI success", { value: nil }, goal)).to eq("unknown")
    end

    it "bands the wall by the goal, and by twice the goal", :aggregate_failures do
      expect(verdict("CI wall", { value: 3.0 }, goal)).to eq("ok")
      expect(verdict("CI wall", { value: 6.0 }, goal)).to eq("attention")
      expect(verdict("CI wall", { value: 6.1 }, goal)).to eq("failed")
    end

    it "takes a goal the QualityControl world declares over the bluebook's", :aggregate_failures do
      expect(verdict("CI wall", { value: 6.0 }, goal.merge(wall_goal_minutes: 2))).to eq("failed")
    end

    it "nudges unpushed commits at the push limits, by count or by age", :aggregate_failures do
      limits = { commits: 15, hours: 6.0 }
      expect(verdict("Commits not pushed", { ahead: 15, age_hours: 0.0 }, limits)).to eq("attention")
      expect(verdict("Commits not pushed", { ahead: 1, age_hours: 6.0 }, limits)).to eq("attention")
      expect(verdict("Commits not pushed", { ahead: 1, age_hours: 5.9 }, limits)).to eq("ok")
    end

    it "presses dispatched sessions at the cap or when one is blocked", :aggregate_failures do
      expect(verdict("Dispatched sessions", { dispatched: 8, blocked: 0 }, session_cap: 8)).to eq("attention")
      expect(verdict("Dispatched sessions", { dispatched: 1, blocked: 1 }, session_cap: 8)).to eq("attention")
      expect(verdict("Dispatched sessions", { dispatched: 7, blocked: 0 }, session_cap: 8)).to eq("ok")
    end
  end

  describe "a session's status" do
    it "is blocked only when the job waits on a person", :aggregate_failures do
      expect(verdict("Session status", { waiting: 1, needs: 1, busy: 0, failed: 0 })).to eq("blocked")
      expect(verdict("Session status", { waiting: 1, needs: 0, busy: 0, failed: 0 })).to eq("busy")
    end

    it "is busy when working, failed on an error, else done", :aggregate_failures do
      expect(verdict("Session status", { waiting: 0, needs: 0, busy: 1, failed: 0 })).to eq("busy")
      expect(verdict("Session status", { waiting: 0, needs: 0, busy: 0, failed: 1 })).to eq("failed")
      expect(verdict("Session status", { waiting: 0, needs: 0, busy: 0, failed: 0 })).to eq("done")
    end
  end

  describe "the fan-out" do
    let(:busy) do
      [{ id: "a", status: "busy", work_item: "one" }, { id: "b", status: "busy", work_item: "one" },
       { id: "c", status: "busy", work_item: "two" }]
    end
    let(:work) do
      [{ slug: "one", status: "started", area: ["lib/x"], claimed_by: "" },
       { slug: "two", status: "planned", area: ["lib/x/y"], claimed_by: "c" }]
    end
    let(:kinds) do
      mapped = board::Fanout.mapping(sessions: busy, work: work, landed: %w[two], fill: {})
      board::Fanout.flags_of(mapped).map { |flag| flag[:kind] }.uniq
    end

    it "flags only, and every, kind the bluebook's Finding rows declare" do
      expect(kinds).to match_array(described_class.finding_kinds)
    end
  end

  describe "the page's steps" do
    let(:actions) { board::Actions }

    it "knows every step the ActionRule rows name" do
      names = described_class.rows("ActionRule").map { |row| row[:action] }
      expect(names.all? { |name| actions.known?(name) }).to be(true)
    end

    it "has an answer check the run first, and no other step a first command", :aggregate_failures do
      expect(actions.before("answer", { target: "run-1" })).to eq(%w[AgentRun.check! to=run-1 --wait])
      expect(actions.before("promote", {})).to be_nil
    end

    it "has an answer fall back to a reply when its run has ended, and no other step a fallback", :aggregate_failures do
      expect(actions.ended("answer")).to eq("reply")
      expect(actions.ended("promote")).to be_nil
    end

    it "knows no other step" do
      expect(actions.known?("rm")).to be(false)
    end

    it "builds a step's arguments from its row", :aggregate_failures do
      expect(actions.argv("delete", { target: "r1" }, confirm: true)).to eq(["AgentRun.tidy!", "to=r1"])
      expect(actions.program("reply")).to eq("claude")
    end

    it "refuses a step that needs confirm, or a field it lacks", :aggregate_failures do
      expect { actions.argv("delete", { target: "r1" }, confirm: false) }.to raise_error(board::Unavailable, /confirm/)
      expect { actions.argv("answer", { target: "r1" }, confirm: false) }.to raise_error(board::Unavailable, /text/)
    end
  end

  describe "the adapters" do
    # A state word an adapter writes itself is a rule that has left the bluebook. (pipeline_jobs.rb
    # is not listed: it reads the job's own words, `blocked` and `failed`, as input.)
    RULE_FREE = %w[pipeline_stages/strip.rb pipeline_stages/ci_tiles.rb pipeline_stages/work_tiles.rb
                   pipeline_web/actions.rb].freeze

    it "decide no state themselves", :aggregate_failures do
      RULE_FREE.each do |file|
        source = File.read(File.join(adapters, file))
        expect(source).not_to match(/state: "(ok|attention|working|failed)"/), "#{file} writes a state itself"
        expect(source).not_to match(/\? "(ok|attention)" : "(ok|attention)"/), "#{file} picks a state itself"
      end
    end
  end
end
