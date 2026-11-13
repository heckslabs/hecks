require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

# A finished run whose session was pruned, through the booted Hecks domain. A stand-in `claude` is
# first on the search path and lists the sessions the example writes, so no real session is listed,
# read or removed. Its tidy finds the listing does not hold the session, so the run is recorded
# tidied, the reap does not review it again, and a plan review it left without a verdict is
# unstarted.
RSpec.describe "A finished run whose session was pruned" do
  PRUNED_STAND_IN = <<~SH.freeze
    #!/bin/sh
    here=$(dirname "$0")
    if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
    if [ "$1" = "rm" ]; then echo "$2" >> "$here/rm.log"; exit 0; fi
    if [ "$1" = "--agent" ] && [ "$2" = "hecks-probe-not-an-agent" ]; then
      printf 'Available agents: architect\\n'; exit 0
    fi
    printf 'backgrounded · stand-in-session\\n'
  SH

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:scratch) { File.realpath(Dir.mktmpdir("agent-pruned")) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    install_stand_in
    ENV["PATH"] = "#{scratch}:#{env["PATH"]}"
    ENV["HOME"] = scratch
    example.run
  ensure
    ENV.update(env)
    FileUtils.rm_rf(scratch)
  end

  before do
    @clock = Time.now.utc
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0, now: -> { @clock } })
    end)
  end

  def install_stand_in
    path = File.join(scratch, "claude")
    File.write(path, PRUNED_STAND_IN)
    File.chmod(0o755, path)
  end

  def listing(*entries) = File.write(File.join(scratch, "sessions.json"), JSON.generate(entries))

  def job(state)
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: state))
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  def tidy(run) = JSON.parse(launch("agent_run.tidy!", "to=#{run}", "--wait").first.to_s)

  def dispatch(run) = launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=say ok", "--wait")

  # An architect run for a plan review, dispatched by the request itself.
  def request_review(run)
    launch("agents", "PlanReview.request!", "run.value=#{run}", "work.value=w-#{run}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=plan", "--wait")
  end

  def review_of(run) = launch("agents", "PlanReview.of_run", "run.value=#{run}").first.to_s

  # A run that finished done, whose session the listing then dropped, an hour after it started.
  def pruned_run(run, start: method(:dispatch))
    listing({ id: "stand-in-session", sessionId: "0000aaaa-1111", state: "working" })
    job("working")
    start.call(run)
    job("done")
    launch("agent_run.check!", "to=#{run}", "--wait")
    listing
    @clock += 3600
  end

  it "records the run tidied, since the listing no longer holds its session", :aggregate_failures do
    pruned_run("p-gone")
    outcome = tidy("p-gone")
    expect(outcome.dig("state", "status")).to eq("tidied")
    expect(outcome["events"]).to include("SessionReviewed")
  end

  it "leaves the tidied run out of the runs a reap tidies", :aggregate_failures do
    pruned_run("p-once")
    tidy("p-once")
    expect(launch("AgentRun.tidyable").first.to_s).not_to include("p-once")
    expect(launch("agent_run.tidy!", "to=p-once", "--wait").first.to_s).not_to include("ReviewRefused")
  end

  it "unstarts the plan review a tidied architect run left without a verdict", :aggregate_failures do
    pruned_run("p-review", start: method(:request_review))
    expect(tidy("p-review").dig("state", "status")).to eq("tidied")
    expect(review_of("p-review")).to include("the architect's session is gone and gave no verdict")
  end

  it "keeps a finished run whose sessions cannot be listed, with the listing's own refusal", :aggregate_failures do
    pruned_run("p-down")
    File.write(File.join(scratch, "claude"), "#!/bin/sh\necho 'daemon down' >&2\nexit 1\n")
    outcome = tidy("p-down")
    expect(outcome.dig("state", "status")).to eq("finished")
    expect(outcome["events"]).not_to include("SessionLookedFor")
  end
end
