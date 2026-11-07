require "spec_helper"
require "open3"
require_relative "support/stand_in_claude"

# A coder's run that ends done with a report whose last word is `submitted` submits its branch
# with no hand call: the job read carries the branch, commit and cleanliness of the run's
# checkout, and `Submission.Submit` refuses main, stable and a dirty tree by name. The checkout is
# a scratch git repository and `claude` is a stand-in, so no real session runs and no live state
# is touched.
RSpec.describe "a coder that ends done submitting its own branch" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-c", "user.name=Spec", "-c", "user.email=spec@example.com", *args, chdir: dir)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out.strip
  end

  # A scratch repository on `branch` with one commit; `dirty` leaves an untracked file beside it.
  def checkout(branch, dirty: false)
    dir = File.join(scratch, "work-#{branch}")
    FileUtils.mkdir_p(dir)
    git(dir, "init", "-q", "-b", branch)
    File.write(File.join(dir, "change.rb"), "# a change\n")
    commit(dir, dirty)
  end

  def commit(dir, dirty)
    git(dir, "add", "change.rb")
    git(dir, "commit", "-q", "-m", "a change")
    File.write(File.join(dir, "stray.txt"), "left over\n") if dirty
    dir
  end

  def finish(run, dir, report, agent: "coder")
    launch("AgentRun.dispatch!", "run.value=#{run}", "repo.value=#{dir}", "brief.value=build it",
           "agent.value=#{agent}", "--wait")
    state = { state: "done", detail: "finished", output: { result: report } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def submissions = @hecks.registry.reaction_log.select { |r| r[:policy] == "SubmitWhenTheCoderSaysSubmitted" }

  def reviews = launch("agents", "SubmissionReview.reviews").first.to_s

  it "submits the branch at its commit when the report ends with submitted", :aggregate_failures do
    dir = checkout("w-done")
    finish("w-done", dir, "Branch w-done, specs pass.\n\nsubmitted")
    expect(submissions.last[:delivered]).to be(true)
    expect(reviews).to include(git(dir, "rev-parse", "HEAD"), "w-done")
  end

  # The stand-in's one job already reads done, so the reviewer's run is read finished at once.
  def reviewer_run(sha) = JSON.parse(launch("agent_run.tidyable").first.to_s).find { |run| run["run"] == sha }

  it "starts the reviewer's run in the coder's checkout" do
    dir = checkout("w-repo")
    finish("w-repo", dir, "submitted")
    expect(reviewer_run(git(dir, "rev-parse", "HEAD"))).to include("repo" => "#{dir}/", "agent" => "reviewer")
  end

  it "submits nothing when the report ends with another word" do
    dir = checkout("w-blocked")
    finish("w-blocked", dir, "Could not finish: the spec fails.\n\nblocked")
    expect(reviews).not_to include(git(dir, "rev-parse", "HEAD"))
  end

  it "refuses a dirty tree by name" do
    finish("w-dirty", checkout("w-dirty", dirty: true), "submitted")
    expect(submissions.last[:reason].to_s).to include("tree is clean")
  end

  it "refuses a submission of main by name" do
    finish("w-main", checkout("main"), "submitted")
    expect(submissions.last[:reason].to_s).to include("never main or stable")
  end

  it "submits nothing for an architect whose report ends with submitted" do
    dir = checkout("w-arch")
    finish("w-arch", dir, "submitted", agent: "architect")
    expect(reviews).not_to include(git(dir, "rev-parse", "HEAD"))
  end
end
