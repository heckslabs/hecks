require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"

# The sequence of 2026-11-12, replayed on a Memory boot: a work item starts, its branch lands while
# the reaction that finishes it is lost, its session ends done, and the settle that follows would
# have yielded it back to the plan. The landing is found and the work item is finished instead.
#
# The Landing records are stood in, since a Memory boot holds none across processes; what this
# proves is the settle's logic over them. The live checkout persists `Hecks::Landing` in its local
# hecksagon, which is where a settle in production reads them.
RSpec.describe Hecks::Adapters::Dispatching, "#conclude" do
  let(:key) { "red-board-push-spec-plan-tile" }
  let(:registry) { boot_hecks_in_memory.registry }
  let(:runner) { described_class::InProcessRunner.new(registry) }
  let(:repo) { Dir.mktmpdir("landed-replay") }

  after { FileUtils.rm_rf(repo) }

  # A repository with one commit made a minute after the work item started, as a coder's is.
  def landed_commit
    stamp = (Time.now.utc + 60).iso8601
    env = { "GIT_AUTHOR_DATE" => stamp, "GIT_COMMITTER_DATE" => stamp }
    system("git", "init", "-q", repo, exception: true)
    system(env, "git", "-C", repo, "-c", "user.name=spec", "-c", "user.email=spec@example.com", "commit", "-q",
           "--allow-empty", "-m", "fix", exception: true)
    Hecks::Adapters::Shell.new.capture("git", "rev-parse", "HEAD", chdir: repo).out.strip
  end

  def start_the_work_item
    runner.call(["tickets", "Work.plan!", "work.value=#{key}", "title.value=Red: the board push spec", "--wait"])
    runner.call(["tickets", "Work.start!", "to=#{key}", "claimed_by.value=dispatch",
                 "claimed_at.value=#{Time.now.utc.iso8601}", "--wait"])
  end

  # The work items as the registry holds them, with the run ended done and the branch's landing.
  def work_items(sha)
    items = described_class::WorkItems.new(registry)
    ended = { key => { status: "finished", condition: "done", started_at: "" } }
    allow(items).to receive_messages(runs: ended, landed_commits: [sha])
    items
  end

  def replay
    start_the_work_item
    items = work_items(landed_commit)
    settings = { work_items: items, runner: runner, load: -> { 0.5 }, cpus: 4 }
    dispatching = described_class.new(registry: registry, settings: settings)
    [dispatching.conclude(repo: { value: repo }).dig(:report, :value), items, dispatching]
  end

  def work_events(name) = registry.event_log.count { |event| event.name == name && event.id.to_s == key }

  it "finishes the work item instead of yielding it", :aggregate_failures do
    report, items, = replay

    expect(report).to match(/\Afinished #{key}.*: landed as \h{9}, finishing instead\z/)
    expect(items.work_status(key)).to eq("done")
  end

  it "starts it once and never yields it", :aggregate_failures do
    replay

    expect(work_events("WorkStarted")).to eq(1)
    expect(work_events("WorkYielded")).to eq(0)
  end

  it "leaves it out of what a filling would choose" do
    _, _, dispatching = replay

    expect(dispatching.preview(repo: { value: repo })[:text]).not_to include(key)
  end
end
