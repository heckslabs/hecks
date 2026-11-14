# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# The end a check records is itself a reaction, so the owner's switch is read deep in a chain:
# the consult and the read still fit, and the roll that follows an on switch ends recorded.
RSpec.describe "the owner's switch when a check finds a run ended", :aggregate_failures do
  include_context "with a reaping fleet"

  before do
    File.write(File.join(scratch, "sessions.json"), "[]")
    transcript([user("go")])
  end

  def recorded = @hecks.registry.event_log.map(&:name)

  def switch_on
    allow(Hecks::Adapters::Dispatching::Settings).to(receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |world| allow(world).to receive(:roll_forward?).and_return(true) }
    end)
  end

  it "requests no roll while the switch is off, and records the pause" do
    finished_run("r-paused")

    expect(recorded).to include("SessionFinished", "RollPaused")
    expect(recorded).not_to include("RollRequested")
  end

  it "requests a roll and records its end while the switch is on" do
    switch_on
    finished_run("r-rolling")

    expect(recorded).to include("SessionFinished", "RollRequested")
    expect(recorded.count("RollRequested")).to eq(recorded.count("RollAnswered") + recorded.count("RollDeclined"))
  end
end
