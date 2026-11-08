require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/boarding_holding"
require "hecks/hecks/adapters/boarding_releasing"
require "tmpdir"
require "open3"

# A hold on local main for a boarding: the adapter writes, reads and lifts the marker, and a landing
# onto main is refused by name while it stands, except a red Work item's fix. Every example builds
# its own throwaway repository; nothing reads the owner's.
RSpec.describe Hecks::Adapters::BoardingHolding, "#mark" do
  let(:dir) { Dir.mktmpdir("hecks-boarding-hold") }
  let(:repo) { File.join(dir, "main") }
  let(:now) { [Time.now] }
  let(:holding) { described_class.new(settings: { clock: -> { now.first } }) }
  let(:releasing) { Hecks::Adapters::BoardingReleasing.new(settings: { clock: -> { now.first } }) }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def branch_with_commit(name)
    tree = File.join(dir, name.tr("/", "_"))
    git("worktree", "add", "-b", name, tree)
    File.write(File.join(tree, "#{name.tr("/", "_")}.txt"), "x")
    git("add", ".", chdir: tree)
    git("commit", "-m", name, chdir: tree)
  end

  def build_repo(*branches)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    File.write(File.join(repo, "README"), "x")
    git("add", ".")
    git("commit", "-m", "first")
    branches.each { |name| branch_with_commit(name) }
  end

  def hold(owner: "rehearser") = holding.mark(checkout: repo, owner: { value: owner })

  def land(branch, **tune) = Hecks::Adapters::GitLanding.new(**tune).merge(checkout: repo, branch: branch)

  def landed? = git("branch", "--merged", "main")

  it "holds main for the commit it is at, with owner and reason" do
    build_repo
    said = hold.dig(:output, :value)

    expect(said).to include("held:", "boarding #{git("rev-parse", "main")[0, 9]}", "owner rehearser")
  end

  def state = holding.status(checkout: repo)[:text][/\A\w+/]

  it "reports no hold, then the hold, then none again after a release" do
    build_repo
    seen = [state, hold && state, releasing.clear(checkout: repo) && state]

    expect(seen).to eq(%w[not held not])
  end

  it "refuses a landing by name while main is held", :aggregate_failures do
    build_repo("feature-x")
    hold

    named = /main is frozen for boarding #{git("rev-parse", "main")[0, 9]} by rehearser: retry after release/

    expect { land("feature-x") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, named)
    expect(landed?).not_to include("feature-x")
  end

  it "refuses a finish before it rebases or gates anything" do
    build_repo("feature-x")
    hold

    expect { Hecks::Adapters::GitLanding.new.finish_branch(checkout: repo, branch: "feature-x") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main is frozen for boarding/)
  end

  it "lands the fix of a red Work item while main is held" do
    build_repo("red-ci-fuzz")
    hold

    expect(land("red-ci-fuzz").dig(:outcome, :value)).to eq("fast_forwarded")
  end

  it "lands again once the hold is released" do
    build_repo("feature-x")
    hold
    releasing.clear(checkout: repo)

    expect(land("feature-x").dig(:outcome, :value)).to eq("fast_forwarded")
  end

  it "stops holding after the window, so main is never held longer than it" do
    build_repo("feature-x")
    hold
    now[0] += 21 * 60

    expect(holding.status(checkout: repo)[:text]).to start_with("expired (ignored)")
  end

  it "lands once the hold has expired" do
    build_repo("feature-x")
    expired = Time.now - (21 * 60)
    described_class.new(settings: { clock: -> { expired } }).mark(checkout: repo)

    expect(land("feature-x").dig(:outcome, :value)).to eq("fast_forwarded")
  end
end
