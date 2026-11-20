require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/red_flagging"
require "tmpdir"
require "open3"
require_relative "support/landing_holds_registry"

# A landing takes no place in a line. It builds the commit it lands as, then moves the target only
# if the target still points where the landing started; when it moved, the landing is built again.
# Every example builds its own throwaway repository and stands in for the gate.
RSpec.describe Hecks::Adapters::GitLanding, "#merge by compare-and-swap" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-swap")) }
  let(:repo) { File.join(dir, "main") }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:calls) { [] }

  after { FileUtils.remove_entry(dir) }

  # The landing runs a plain `git merge`, which makes a commit and so needs a committer. A
  # developer's machine has one in its global config; a CI runner has none, and the merge then
  # fails with no conflict to name ("merging a into main conflicts in ;"). The spec supplies the
  # identity itself.
  around do |example|
    names = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL]
    saved = ENV.values_at(*names)
    names.each { |name| ENV[name] = name.end_with?("NAME") ? "t" : "t@t" }
    example.run
  ensure
    names.zip(saved) { |name, value| ENV[name] = value }
  end

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

  def tree(name) = File.join(dir, "tree-#{name}")

  def build_repo(*branches)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    branches.each do |name|
      git("worktree", "add", "-b", name, tree(name))
      commit(tree(name), "#{name}.txt")
    end
  end

  def tip(branch) = git("rev-parse", branch).strip

  def subjects = git("log", "--format=%s", "main").split("\n")

  def green
    ended = instance_double(Process::Status, success?: true)
    Hecks::Adapters::Shell::Result.new("{\"status\": \"completed\"}", "", ended)
  end

  def landing = described_class.new(registry: LandingHoldsRegistry.landing_holds_registry)

  def land(name) = landing.merge(checkout: tree(name), branch: name, onto: "main")

  # A landing in a process of its own, which leaves a file saying why when the branch did not land.
  def land_apart(name)
    fork do
      land(name)
      exit!(0)
    rescue StandardError => e
      File.write(File.join(dir, "#{name}.refused"), e.message)
      exit!(1)
    end
  end

  def refusals = Dir.glob(File.join(dir, "*.refused")).map { |file| File.read(file) }

  # A gate stand-in that is green, and moves main under the landing at each of its first calls.
  def gate_moving_main(times, &also)
    lambda do |_dir|
      calls << 1
      commit(repo, "moved#{calls.size}.txt") if calls.size <= times
      also&.call
      green
    end
  end

  def finish(gate) = landing.finish_branch(checkout: tree("a"), branch: "a", onto: "main", gate: gate)

  def swap = described_class::Swap.new(Hecks::Adapters::Git.new, repo, onto: "main")

  it "lands branches started together, and none takes a place in a line", :aggregate_failures do
    build_repo("a", "b", "c", "d")
    %w[a b c d].map { |name| land_apart(name) }.each { |pid| Process.wait(pid) }

    expect(refusals).to eq([])
    expect(subjects).to include("a.txt", "b.txt", "c.txt", "d.txt")
    expect(File.exist?(File.join(repo, ".git", "hecks-landing"))).to be(false)
  end

  it "lands at once while a ticket holds the front of the train's line" do
    build_repo("a")
    held = described_class::Line.new(File.join(repo, ".git")).join("other", ready: true)

    expect(land("a").dig(:outcome, :value)).to eq("merged")
    held.close
  end

  it "builds a merge commit beside main when the branch is not built on it", :aggregate_failures do
    build_repo("a")
    commit(repo, "later.txt")

    expect(land("a").dig(:outcome, :value)).to eq("merged")
    expect(git("status", "--porcelain")).to eq("")
    expect(File.exist?(File.join(repo, "a.txt"))).to be(true)
  end

  it "moves a main that no worktree holds" do
    build_repo("a")
    git("checkout", "--detach")

    expect(land("a").dig(:landed, :value)).to eq(tip("main"))
  end

  it "loses the swap when main moved, and changes nothing", :aggregate_failures do
    build_repo("a")
    before = tip("main")
    commit(repo, "later.txt")

    expect { swap.move(before, tip("a")) }.to raise_error(described_class::Swap::Lost, /main moved/)
    expect(subjects).not_to include("a.txt")
  end

  it "refuses a main checkout that holds unsaved work, without another try", :aggregate_failures do
    build_repo("a")
    before = tip("main")
    File.write(File.join(repo, "stray.txt"), "x")

    expect { land("a") }.to raise_error(failure, /stray\.txt/)
    expect(tip("main")).to eq(before)
  end

  it "refuses by name when git's own lock never clears, and does not call it a moved main", :aggregate_failures do
    build_repo("a")
    stub_const("#{described_class}::Swap::LOCK_TRIES", 2)
    File.write(File.join(repo, ".git", "refs", "heads", "main.lock"), "")

    expect { land("a") }.to raise_error(failure, /git's own lock on main did not clear/)
    expect(git("rev-parse", "main").strip).not_to eq(tip("a"))
  end

  it "says so when main moved and the main checkout's files could not follow", :aggregate_failures do
    build_repo("a")
    stub_const("#{described_class}::Swap::LOCK_TRIES", 2)
    File.write(File.join(repo, ".git", "index.lock"), "")

    expect(land("a").dig(:report, :value)).to match(/main moved, but the files in .* did not follow .*read-tree -m -u/)
    expect(subjects).to include("a.txt")
  end

  it "moves the main checkout's files with main, and leaves it clean", :aggregate_failures do
    build_repo("a")
    land("a")

    expect(File.exist?(File.join(repo, "a.txt"))).to be(true)
    expect(git("status", "--porcelain")).to eq("")
  end

  it "rebases and asks the gate again when main moved after the gate, and lands one merge", :aggregate_failures do
    build_repo("a")
    said = finish(gate_moving_main(1)).dig(:report, :value)

    expect([calls.size, said]).to match([2, /main moved 1 time meanwhile/])
    expect(subjects).to include("a.txt", "moved1.txt")
    expect(git("rev-list", "--merges", "main").split.size).to eq(1)
  end

  it "lands a finish as a merge whose tree is the judged tip's" do
    build_repo("a")
    finish(gate_moving_main(1))

    expect(git("rev-parse", "main^{tree}")).to eq(git("rev-parse", "main^2^{tree}"))
  end

  it "refuses by name when main moves at every try, with the branch as it was", :aggregate_failures do
    build_repo("a")

    expect { finish(gate_moving_main(99)) }.to raise_error(failure, /main moved 5 times while a was landing/)
    expect(calls.size).to eq(5)
    expect(subjects).not_to include("a.txt")
    expect(git("log", "--format=%s", "a")).to include("a.txt")
  end

  it "sees a red flag raised between two tries, and stops", :aggregate_failures do
    build_repo("a")
    flagging = Hecks::Adapters::RedFlagging.new(checkout: repo)
    gate = gate_moving_main(1) { flagging.hoist(commit: "abcdef1234567", detail: "abc: run 7 failure") }

    expect { finish(gate) }.to raise_error(failure, /main is red/)
    expect(subjects).not_to include("a.txt")
  end
end
