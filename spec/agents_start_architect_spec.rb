require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A plan review asked for by event starts the architect's session through AgentRun. A stand-in
# `claude` names its agents and starts a session, so no real session runs: the spec shows the
# request becomes a run keyed by the Work item, and a request past the hop limit starts nothing.
RSpec.describe "a plan review request starting the architect's session" do
  STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "--agent" ] && [ "$2" = "hecks-probe-not-an-agent" ]; then
      printf 'Available agents: architect, coder\\n'; exit 0
    fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("architect-start")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    File.write(File.join(scratch, "claude"), STAND_IN)
    File.chmod(0o755, File.join(scratch, "claude"))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", state: "working" }]))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "working"))
    ENV["PATH"] = "#{scratch}:#{env["PATH"]}"
    ENV["HOME"] = scratch
    example.run
  ensure
    ENV.update(env)
    FileUtils.rm_rf(scratch)
  end

  before do
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 })
    end)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def request(work, hops)
    launch("agents", "PlanReview.request!", "work.value=#{work}", "hops.value=#{hops}", "role.value=architect",
           "repo.value=#{scratch}", "plan.value=review this plan", "--wait").first.to_s
  end

  it "starts a run keyed by the Work item for a request under the hop limit" do
    request("w-start", 1)
    expect(launch("agent_run.running").first.to_s).to include("w-start")
  end

  def close_job(text)
    state = { state: "done", detail: "reviewed", output: { result: text } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", state: "done" }]))
  end

  def verdict_reactions
    @hecks.registry.reaction_log.select { |r| r[:policy] == "RecordTheArchitectsVerdict" }
  end

  it "records the verdict the session closed with on the review", :aggregate_failures do
    request("w-verdict", 1)
    close_job("Verdict: sound with changes. Revise the plan as the findings say.")
    launch("agent_run.check!", "to=w-verdict", "--wait")
    expect(verdict_reactions.map { |r| r[:delivered] }).to eq([true])
    expect(launch("agents", "PlanReview.reviews").first.to_s).to include("w-verdict", "changes", "Revise the plan")
  end

  it "starts no run for a request at the hop limit", :aggregate_failures do
    expect(request("w-stop", 3)).to include("under the hop limit")
    expect(launch("agent_run.running").first.to_s).not_to include("w-stop")
  end
end
