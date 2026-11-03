require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

# A landed branch finishes the Work row it was cut for: the row named by the whole branch name, else
# by the name without a leading `qa/`. A landing with no open row does nothing, and a row already
# done is left alone. The domain is in Memory; the repository is a throwaway one and the push
# rehearsal is stubbed.
RSpec.describe "a landing followed by its Work row" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-work")) }
  let(:repo) { File.join(dir, "main") }
  let(:stages) { instance_double(Hecks::Adapters::GitRehearsal::Stages, run: []) }

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false,
                                                                            environment:     HecksMemoryEnvironment::NAME)
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_return(stages)
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file)
    File.write(File.join(where, file), "x")
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

  def plan(key) = launch("tickets", "work.plan!", "work.value=#{key}", "title.value=Step #{key}", "decision=0174", "--wait")

  def status_of(key)
    out, = launch("tickets", "work.undone")
    JSON.parse(out).find { |row| row["work"] == key }&.fetch("status")
  end

  def land(branch)
    tree = File.join(dir, branch.tr("/", "-"))
    git("worktree", "add", "-b", branch, tree)
    commit(tree, "#{branch.tr("/", "-")}.rb")
    launch("landing.land!", "run=l-#{SecureRandom.hex(4)}", "checkout.value=#{tree}", "branch.value=#{branch}",
           "--confirm", "--wait")
  end

  it "finishes the row named by the whole branch name" do
    key = "whole/#{SecureRandom.hex(3)}"
    plan(key)
    land(key)

    expect(status_of(key)).to be_nil
  end

  it "finishes the row named by the branch without a leading qa/" do
    key = "bare#{SecureRandom.hex(3)}"
    plan(key)
    land("qa/#{key}")

    expect(status_of(key)).to be_nil
  end

  it "does nothing when the branch names no row", :aggregate_failures do
    plan("other#{SecureRandom.hex(3)}")
    land("lonely/#{SecureRandom.hex(3)}")

    expect(JSON.parse(launch("tickets", "work.undone").first).size).to be >= 1
    expect(git("rev-parse", "main")).not_to be_empty
  end

  it "leaves a row that is already done alone, with no refused reaction" do
    key = "done#{SecureRandom.hex(3)}"
    plan(key)
    launch("tickets", "work.finish!", "to=#{key}", "--wait")

    expect { land(key) }.not_to output(/reaction .* was refused/).to_stderr
  end
end
