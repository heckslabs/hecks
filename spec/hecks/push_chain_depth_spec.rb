require "spec_helper"

# The push train's reaction chain in the Hecks deliver bluebook, step by step from a boarding to the
# launcher refresh and the deploy announcement. Each step is one nested reaction, and the dispatcher
# refuses a reaction once the cascade reaches its depth, so the last step must stay under it.
RSpec.describe "the push train's reaction chain" do
  # Each step: the policy, and the event it reacts to. The event of each step is emitted by the
  # step before it, so the list's length is the depth of its last reaction.
  CHAIN = [
    %w[MintBeforeCarry SendTrain.BoardingRequested],
    %w[ClearWhenMinted Era.Minted],
    %w[CarryWhenCleared SendTrain.BoardingCleared],
    %w[RecordThePush SendTrain.TrainAnswered]
  ].freeze

  # The policies that run beside the chain's last step, on the same event.
  LAST_STEP = %w[KeepTheLauncherCurrent AnnounceWhenPushed].freeze

  def self.policies
    @policies ||= Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__))
                       .registry.bluebooks["Hecks"].policies.to_h { |policy| [policy.hecks_name, policy] }
  end

  def event_of(name)
    policy = self.class.policies.fetch(name)
    "#{policy.event_qualifier}.#{policy.event_name}"
  end

  CHAIN.each do |name, event|
    it "has #{name} react to #{event}" do
      expect(event_of(name)).to eq(event)
    end
  end

  LAST_STEP.each do |name|
    it "has #{name} react beside RecordThePush, on the train's answer" do
      expect(event_of(name)).to eq(CHAIN.last.last)
    end
  end

  it "keeps the chain's last reaction under the dispatcher's reaction depth" do
    expect(CHAIN.size).to be < Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH
  end
end
