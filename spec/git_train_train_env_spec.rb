# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/codebase/slot_queue"

# A boarding's own checks rank as the train's in the heavy-job queue.
RSpec.describe Hecks::Adapters::GitTrain::TrainEnv do
  def priority(env) = Hecks::Adapters::Codebase::SlotQueue.priority_of(env)

  it "ranks a boarding's own check as the train's in the heavy-job queue" do
    env = described_class.for("abc123", {})

    expect(priority(env)).to eq(Hecks::Adapters::Codebase::SlotQueue::TRAIN)
  end

  it "keeps the configuration the environment already holds" do
    env = described_class.for("abc123", { "GIT_CONFIG_PARAMETERS" => "'a.b=c'" })

    expect(env["GIT_CONFIG_PARAMETERS"]).to eq("'a.b=c' 'hecks.trainCarry=abc123'")
  end

  it "reaches the drift checks a settlement runs", :io do
    out = drift_env_printed("abc123")

    expect(out).to include("hecks.trainCarry=abc123")
  end

  def drift_env_printed(commit)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "env")
      guard = instance_double(Hecks::Adapters::GitTrain::BranchGuard, head: commit)
      check = ["sh", "-c", "printf %s \"$GIT_CONFIG_PARAMETERS\" > #{path}"]
      Hecks::Adapters::GitTrain::DriftChecks.new(dir, guard, [check]).run(commit)
      File.read(path)
    end
  end
end
