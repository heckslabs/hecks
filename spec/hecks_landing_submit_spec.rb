require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

# A coder submits and ends its turn; the landing is a job of its own. A submission hands the
# branch to the job, and a job's landing refused for a cause a coder can fix plans the finished
# Work item again with the reason. The domain is in Memory, the repository is a throwaway one and
# the job's process is a stand-in, so nothing is spawned.
RSpec.describe "a submitted branch handed to its landing job" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-submit")) }
  let(:repo) { File.join(dir, "main") }
  let(:job) { instance_double(Hecks::Adapters::GitLanding::Job, start: "handed") }

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    allow(Hecks::Adapters::GitLanding::Job).to receive(:new).and_return(job)
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file, text = "x")
    File.write(File.join(where, file), text)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def undone(key) = JSON.parse(launch("tickets", "work.undone").first).find { |item| item["work"] == key }

  # A finished Work item whose branch, cut in its own worktree, changes the file main changes
  # too, so its rebase conflicts.
  def finished(key, detail: "build it")
    launch("tickets", "work.plan!", "work.value=#{key}", "title.value=Step #{key}", "detail.value=#{detail}", "--wait")
    launch("tickets", "work.finish!", "to=#{key}", "--wait")
    tree = File.join(dir, key)
    git("worktree", "add", "-b", key, tree)
    commit(tree, "README", "theirs")
    commit(repo, "README", "ours")
    tree
  end

  def land(verb, key, tree)
    launch("landing.#{verb}!", "run=f-#{SecureRandom.hex(4)}", "checkout.value=#{tree}", "branch.value=#{key}",
           "--confirm", "--wait")
  end

  it "starts the landing job when a coder submits its branch" do
    tree = finished("sub#{SecureRandom.hex(3)}")
    launch("coder", "Submission.submit!", "branch.value=#{File.basename(tree)}", "checkout.value=#{tree}",
           "sha.value=#{git("rev-parse", "HEAD", chdir: tree).strip}", "clean.value=true", "--wait")

    expect(job).to have_received(:start).with(hash_including(checkout: tree, branch: File.basename(tree)))
  end

  it "hands a submitted branch to the job and lands nothing itself", :aggregate_failures do
    key = "hand#{SecureRandom.hex(3)}"
    out, = land("submit", key, finished(key))

    expect(JSON.parse(out)).to include("events" => %w[LandingSubmitted LandingJobStarted LandingHanded])
    expect(git("log", "--format=%s", "main")).not_to include("theirs")
  end

  it "plans the Work item again with the reason when the job's landing conflicts", :aggregate_failures do
    key = "conf#{SecureRandom.hex(3)}"
    land("carry", key, finished(key))

    expect(undone(key)).to include("status" => "planned")
    expect(undone(key)["detail"]).to match(/build it\n\nLanding refused: .*conflict:/)
  end

  it "leaves the Work item done when the refused finish was a person's own" do
    key = "own#{SecureRandom.hex(3)}"
    land("finish", key, finished(key))

    expect(undone(key)).to be_nil
  end

  it "reopens nothing once the Work item's detail holds two landing refusals" do
    key = "twice#{SecureRandom.hex(3)}"
    tree = finished(key, detail: "build it. Landing refused: conflict: one. Landing refused: conflict: two")
    land("carry", key, tree)

    expect(undone(key)).to be_nil
  end
end
