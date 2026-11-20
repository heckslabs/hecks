# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_state_fixture"

# ADR 0195 point 1: a state is decided only by a `Verdict` row and a threshold only by a `Setting`
# row. These are the rows that took over what an adapter decided before: the disk, the boot
# hours, a number with no bound of its own, a stalled session, a train pull request and a role.
RSpec.describe "PipelineBoard Verdict rows that replaced adapter rules" do
  let(:board) { Hecks::Adapters::PipelineBoard }
  let(:run) { { sha: "a", status: "completed", wall_minutes: 3, failed_jobs: 0 } }

  def ci_stage(conclusion) = board::Strip.ci([run.merge(conclusion: conclusion)])[:state]

  BoardStateFixture::VERDICTS.each do |stage, measures, state|
    it "gives #{stage} #{state} for #{measures}" do
      expect(board::Rules.verdict(stage, measures)).to eq(state)
    end
  end

  it "lets the world's disk floors outrank the Setting rows" do
    expect(board::Rules.verdict("Disk free", { free_gb: 30 }, { disk_attention_gb: 40 })).to eq("attention")
  end

  it "gives a tile with no state of its own the state of the Read rows" do
    expect(board::Metrics.tile("lead", "Commit to green CI", nil, "min")).to include(state: "unknown")
  end

  it "asks one conclusion rule: a cancelled run fails the CI stage, a skipped one does not" do
    expect(%w[cancelled skipped success].map { |word| ci_stage(word) }).to eq(%w[failed ok ok])
  end

  it "counts only a run that passed in the CI success rate" do
    runs = ["success", "skipped", "cancelled", ""].map { |word| { conclusion: word } }
    expect(board::Metrics.success_rate(runs)).to eq(25)
  end
end
