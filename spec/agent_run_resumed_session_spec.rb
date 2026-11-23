require "spec_helper"
require_relative "support/agent_run_resume_helpers"

# `Fleet.resume!` through the booted Hecks domain: the AgentRun that holds the resumed session is
# recorded working again, so the tidy and the pruner no longer read it as finished. A session no
# run holds records nothing. A stand-in `claude` lists the session and takes the resume, so no
# real session is touched.
RSpec.describe "AgentRun follows a session Fleet.resume! woke" do
  include AgentRunResumeHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  it "records the finished run of a resumed session working again", :aggregate_failures do
    finished_run("resumed-one")
    expect(started?("resumed-one")).to be(false)
    resume("stand-in-session")

    expect(started?("resumed-one")).to be(true)
  end

  it "records nothing for a resumed session no run holds" do
    sessions("done", id: "lone-session")

    expect(resume("lone-session").first.to_s).not_to include("AgentRunRevived")
  end
end
