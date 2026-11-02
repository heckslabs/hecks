require "spec_helper"

# The push train's reaction chain in the Hecks deliver bluebook, step by step from a boarding to the
# launcher refresh and the deploy announcement. Each step is one nested reaction, and the dispatcher
# refuses a reaction once the cascade reaches its depth, so the deepest step must stay under it. The
# Hecks mint is no link in it: the carry runs the mint first, then pushes, inside one reaction.
RSpec.describe "the push train's reaction chain" do
  # Each step: the policy, and the event it reacts to. The event of each step is emitted by the
  # step before it, so the list's length is the depth of its last reaction.
  CHAIN = [
    %w[CarryWhenBoarded SendTrain.BoardingRequested],
    %w[RecordThePush SendTrain.TrainAnswered],
    %w[KeepTheLauncherCurrent SendTrain.BranchPushed]
  ].freeze

  # The policies that run at the depth of a step of the chain: the step's policy, and the event
  # they react to, which the step before it emits (the carry answers or refuses).
  BESIDE = { "RecordTheRide"        => %w[RecordThePush SendTrain.TrainAnswered],
             "RecordTheRefusedPush" => %w[RecordThePush SendTrain.TrainRefused],
             "AnnounceWhenPushed"   => %w[KeepTheLauncherCurrent SendTrain.BranchPushed],
             "ListLeftoversWhenPushed" => %w[KeepTheLauncherCurrent SendTrain.BranchPushed] }.freeze

  # Policies that would chain the mint through events; the carry runs it in sequence instead.
  RETIRED = %w[MintBeforeCarry ClearWhenMinted CarryWhenCleared RecordTheRefusedMint].freeze

  def self.bluebook
    @bluebook ||= Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__)).registry.bluebooks["Hecks"]
  end

  def policies = self.class.bluebook.policies.to_h { |policy| [policy.hecks_name, policy] }

  def event_of(name)
    policy = policies.fetch(name)
    "#{policy.event_qualifier}.#{policy.event_name}"
  end

  (CHAIN + BESIDE.map { |name, (_, event)| [name, event] }).each do |name, event|
    it "has #{name} react to #{event}" do
      expect(event_of(name)).to eq(event)
    end
  end

  it "declares none of the mint's chained links" do
    expect(policies.keys & RETIRED).to be_empty
  end

  it "reacts to no event of the Hecks mint" do
    expect(policies.values.map(&:event_name) & %w[Minted MintRefused]).to be_empty
  end

  it "keeps the chain's deepest reaction under the dispatcher's reaction depth" do
    expect(CHAIN.size).to be < Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH
  end
end
