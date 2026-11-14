require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "tmpdir"
require "open3"

# The merge train, on throwaway repositories: ready branches land in ticket order behind the
# holder, a branch that conflicts is skipped with its reason, and each branch meets the gate once.
RSpec.describe Hecks::Adapters::GitLanding do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-train")) }
  let(:repo) { File.join(dir, "main") }
  let(:said) { Queue.new }
  let(:gated) { Queue.new }
  let(:tune) do
    { locks: [], say: ->(text) { said << text }, heartbeat: 0.05, wait_minutes: 1,
      gate: ->(tree) { (gated << File.basename(tree)) && nil } }
  end

  after { FileUtils.rm_rf(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def branch(name, file, body)
    tree = File.join(dir, name)
    git("worktree", "add", "-b", "work/#{name}", tree)
    File.write(File.join(tree, file), body)
    git("add", ".", chdir: tree)
    git("commit", "-m", name, chdir: tree)
    tree
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
    File.write(File.join(repo, "shared.txt"), "base\n")
    git("add", ".")
    git("commit", "-m", "first")
  end

  def trees
    { a: branch("a", "a.rb", "a"), b: branch("b", "shared.txt", "from b\n"),
      c: branch("c", "shared.txt", "from c\n"), d: branch("d", "d.rb", "d") }
  end

  def waiting(tree, name)
    thread = Thread.new do
      Thread.current.report_on_exception = false
      described_class.new(**tune).merge(checkout: tree, branch: "work/#{name}")
    end
    hear("work/#{name} is")
    thread
  end

  def line = Hecks::Adapters::GitLanding::Line.new(File.join(repo, ".git"))

  def hear(text)
    Timeout.timeout(10) { loop { break if said.pop.include?(text) } }
  end

  def convene
    front = line.join("work/front", ready: true)
    threads = trees.to_h { |name, tree| [name, waiting(tree, name.to_s)] }
    report = run_train { line.leave(front) }
    [report, settled(threads)]
  end

  def run_train
    runner = Thread.new { described_class.new(**tune).convene(checkout: repo) }
    hear("train is")
    yield
    runner.value
  end

  def settled(threads) = threads.each_value { |thread| settle(thread) }

  # Waits for a landing thread to finish, whatever became of its branch, so none is still
  # touching the repository when the example's directory is removed.
  def settle(thread)
    thread.join
  rescue Hecks::Adapters::ConsoleCapture::Failure
    nil
  end

  it "lands the ready branches in ticket order and skips the one that conflicts", :aggregate_failures do
    report, = convene

    expect(report.dig(:report, :value)).to match(%r{landed work/a; landed work/b; skipped work/c: .*rebase.*; landed work/d}m)
    expect(git("log", "--format=%s", "-n", "4", "main").split("\n")).to eq(%w[d b a first])
  end

  it "tells the waiting landing of each branch what became of it", :aggregate_failures do
    _, threads = convene

    expect(threads[:a].value.dig(:report, :value)).to include("landed by the train")
    expect { threads[:c].value }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{work/c does not rebase onto main})
  end

  it "returns only once every waiting landing has finished" do
    _, threads = convene

    expect(threads.values).to all(satisfy { |thread| !thread.alive? })
  end

  it "runs the gate once for each branch that reaches it" do
    convene

    expect(Array.new(gated.size) { gated.pop }).to eq(%w[a b d])
  end
end
