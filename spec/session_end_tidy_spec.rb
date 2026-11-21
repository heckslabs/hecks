# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "support/reap_turn"

# A run that failed is tidied on its own, and a reap that died holding the turn stops holding it
# once its lease has passed, so a finished run's session goes then.
RSpec.describe "The session of a run that ended" do
  include_context "with a reaping fleet"
  include_context "with a first beat at noon"

  def end_run(state)
    transcript([user("go")])
    listing("stand-in-session", "done")
    launch("agent_run.dispatch!", "run.value=r-end", "repo.value=#{scratch}", "brief.value=go", "--wait")
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
    launch("agent_run.check!", "to=r-end", "--wait")
  end

  it "stays while a dead reap still holds the turn" do
    killed_reap(at: noon)
    at(noon + 899)
    end_run("done")
    expect(removed).to be_empty
  end

  it "is removed when the run finished after a dead reap's lease" do
    killed_reap(at: noon)
    at(noon + 900)
    end_run("done")
    expect(removed).to eq(["stand-in-session tree=gone"])
  end

  it "is removed when the run failed" do
    end_run("failed")
    expect(removed).to eq(["stand-in-session tree=gone"])
  end

  it "leaves the failed run out of the next reap" do
    end_run("failed")
    expect(launch("agent_run.tidyable")).not_to include("r-end")
  end
end
