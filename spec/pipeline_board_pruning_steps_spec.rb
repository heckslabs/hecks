# frozen_string_literal: true

require "spec_helper"
require_relative "support/fake_journal"
require "hecks/pipeline_board/adapters/pipeline_web"

# The steps that flip the owner's pruning switch: each is one launcher command, and none asks for
# a confirm.
RSpec.describe "the board's pruning steps" do
  let(:sent) { [] }

  def stages(pruning)
    instance_double(Hecks::Adapters::PipelineStages, state: { stages: [], pruning: pruning }, **FakeJournal::TILES)
  end

  def act(action, pruning)
    launcher = ->(*args, **) { sent << args }
    settings = { stages: stages(pruning), background: false, journal: FakeJournal.source, launcher: launcher }
    Hecks::Adapters::PipelineWeb.new(settings: settings).act(action: action, fields: {}, confirm: false)
    sent.last
  end

  it "pauses a seated pruner without a confirm" do
    expect(act("pause_pruning", { state: "running" })).to eq(%w[exe/hecks agents Pruning.pause! to=pruner --wait])
  end

  it "holds a pruner that has no seat" do
    expect(act("pause_pruning", { state: "unseated" })).to eq(%w[exe/hecks agents Pruning.hold! role.value=pruner --wait])
  end

  it "resumes a paused pruner" do
    expect(act("resume_pruning", { state: "paused" })).to eq(%w[exe/hecks agents Pruning.resume! to=pruner --wait])
  end
end
