require "spec_helper"
require_relative "support/shed_looks"

# A rise of the load over the fill's limit asks one started work item, the lowest priority one, to
# yield at its next safe point. The ask is an answer delivered to the working session: nothing is
# stopped. The load series and the listing of started items are fakes; the policies are real.
RSpec.describe "the load sheds the lowest-priority item", :aggregate_failures do
  include ShedLooks

  it "asks the lowest-priority started item when the load rises" do
    running("urgent" => "now", "soon" => "next", "someday" => "later")
    loads(9.0, 11.0)

    expect(asked).to eq(%w[someday])
    expect(events).to include("LoadRoseAbove", "ShedAsked", "LoadYieldAsked", "AnswerQueued")
  end

  it "counts an item with no priority as later, and among equals asks the newest start" do
    running("older" => "later", "newer" => nil, "soon" => "next")
    loads(11.0)

    expect(asked).to eq(%w[newer])
  end

  it "asks with the yield line that names the kind load" do
    running("soon" => "next", "someday" => "later")
    loads(11.0)

    expect(asks.first).to include("Work.yield!", "reason.value=\"load: yielded at the owner's load limit")
    expect(asks.first).to include("yield_kind.value=load")
  end

  it "stops no session" do
    running("soon" => "next", "someday" => "later")
    loads(11.0)

    expect(sessions.stopped).to be_empty
    expect(events).not_to include("SessionFinished", "SessionFailed", "AgentRunRetired")
  end

  # The items a rise never asks: one wanted now, one whose branch is landing, one waiting on its
  # plan review, and the fix of a red main.
  it "never asks a now item" do
    running("urgent" => "now", "also-urgent" => "now")
    loads(11.0)

    expect(asked).to be_empty
    expect(spared).to eq(["no started work item may be shed"])
  end

  it "never asks an item whose branch is landing, and asks the next one" do
    running("landing-now" => "later", "soon" => "next")
    listing.landing_work = %w[landing-now]
    loads(11.0)

    expect(asked).to eq(%w[soon])
  end

  it "never asks a run waiting on its plan review or the fix of a red main" do
    running("reviewed" => "later", "red-main" => "later", "soon" => "next")
    in_review("reviewed")
    loads(11.0)

    expect(asked).to eq(%w[soon])
  end

  # The bounds of the Tickets world's `load_shed`: two coders must run, and one sheds at a time.
  it "asks nobody while fewer than two coders run" do
    running("alone" => "later")
    loads(11.0)

    expect(asked).to be_empty
    expect(spared).to eq(["fewer coders run than load_shed min_coders"])
  end

  it "asks no more on a second rise while one is shedding" do
    running("soon" => "next", "someday" => "later", "whenever" => "later")
    loads(11.0, 9.0, 11.0)

    expect(asked).to eq(%w[whenever])
    expect(spared).to eq(["a run asked to yield has not ended yet (load_shed at_once)"])
  end
end
