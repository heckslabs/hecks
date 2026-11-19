require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/red_wake_repository"

# A wake of the orchestrator for a red main starts its session only while main's red flag stands,
# and only from the main checkout. Through the booted Hecks domain and a stand-in `claude`: a green
# main starts no run, a standing flag starts one run keyed by the flag that plays `red-wake` for
# the episode, a second episode on the same flag starts no second run, a linked worktree starts
# none, and a red-main session read blocked is ended at once.
RSpec.describe "a red-main wake of the orchestrator" do
  include_context "with a stand-in claude"
  include RedWakeRepository

  before(:all) { @hecks = boot_hecks_in_memory }

  before { open_repository }

  it "starts no session while main is not flagged" do
    wake("episode-green")
    expect(red_runs("episode-green")).to be_empty
  end

  it "starts one run keyed by the flag, playing red-wake for the episode, while the flag stands" do
    run = flag!("a1a1a1a1a1a1a1")
    wake("episode-red")
    expect(red_runs("episode-red").map { |held| [held.dig(:run, :value), held.dig(:works_as, :value)] })
      .to eq([[run, "red-wake"]])
  end

  it "starts no second run for a second episode on the same flag" do
    flag!("b2b2b2b2b2b2b2")
    %w[episode-one episode-two].each { |episode| wake(episode) }
    expect(red_runs("episode-one", "episode-two").size).to eq(1)
  end

  it "starts no session from a linked worktree, though the flag stands" do
    flag!("c3c3c3c3c3c3c3")
    git("worktree", "add", "-q", "-b", "side", File.join(scratch, "side"))
    wake("episode-side", at: File.join(scratch, "side"))
    expect(red_runs("episode-side")).to be_empty
  end

  it "ends a red-main session read blocked at once, keeping its question" do
    run = flag!("d4d4d4d4d4d4d4")
    wake("episode-blocked")
    block_the_session
    launch("agent_run.check!", "to=#{run}", "--wait")
    expect(red_runs("episode-blocked").first).to include(condition: { value: "abandoned" }, detail: { value: "which sha?" })
  end
end
