require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# A worktree's write to a shared ledger runs in the main checkout. Every launcher here is a
# stand-in: nothing runs, and no ledger is touched.
RSpec.describe Hecks::Adapters::Driving::LedgerForward do
  around do |example|
    Dir.mktmpdir do |root|
      @root = File.realpath(root)
      example.run
    end
  end

  let(:err) { StringIO.new }
  let(:calls) { [] }

  def main = File.join(@root, "main")

  def worktree = File.join(@root, "worktree")

  def stores
    ledgers = [["store Tickets", "Memory", "root"], ["store Tickets::Work", "SqliteAt /x/tickets.db", "hecksagon"]]
    ->(dir) { dir == main ? ledgers : [["store Tickets", "Memory", "root"]] }
  end

  def runner
    answer = ["planned\n", "", instance_double(Process::Status, exitstatus: 0)]
    ->(*args) { (calls << args) && answer }
  end

  def plan(group: "Work", arguments: [{ path: "checkout.value" }], asking: false)
    { bluebook: Struct.new(:name).new("Tickets"), spec: { group: group, arguments: arguments }, asking: asking }
  end

  def forward(argv, env: {}, **given)
    described_class.call(plan(**given), argv, err, directory: worktree, env: env, stores: stores, runner: runner)
  end

  before do
    FileUtils.mkdir_p([File.join(main, ".git"), File.join(main, "lib/hecks/hecks"), File.join(main, "exe"), worktree])
    FileUtils.touch(File.join(main, "exe/hecks"))
    FileUtils.touch(File.join(main, "lib/hecks/hecks/hecks.local.hecksagon"))
    File.write(File.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/w\n")
  end

  it "runs the line with the main checkout's launcher, in the main checkout, marked as forwarded", :aggregate_failures do
    forward(%w[Work.plan! work.value=x --wait])
    env, launcher, args, directory = calls.first

    expect([launcher, directory]).to eq([File.join(main, "exe/hecks"), main])
    expect(args.first(3)).to eq(%w[Work.plan! work.value=x --wait])
    expect(env).to include("HECKS_FORWARDED" => "1", "BUNDLE_GEMFILE" => nil)
  end

  it "answers what the main checkout answered" do
    expect(forward(%w[Work.plan! work.value=x])).to eq(["planned\n", 0])
  end

  it "relays standard error and answers a failure's error text when it printed nothing else", :aggregate_failures do
    failed = ["", "no such work\n", instance_double(Process::Status, exitstatus: 1)]
    runner_failing = ->(*) { failed }
    text = described_class.call(plan, %w[Work.start!], err, directory: worktree, stores: stores, runner: runner_failing)

    expect(text).to eq(["no such work\n", 1])
  end

  it "relays standard error beside a successful answer" do
    noisy = ["ok\n", "a notice\n", instance_double(Process::Status, exitstatus: 0)]
    described_class.call(plan, %w[Work.plan!], err, directory: worktree, stores: stores, runner: ->(*) { noisy })

    expect(err.string).to eq("a notice\n")
  end

  it "names the worktree when the command takes a checkout and the caller gave none" do
    forward(%w[Work.plan! work.value=x])

    expect(calls.first[2]).to eq(%W[Work.plan! work.value=x checkout.value=#{worktree}])
  end

  it "leaves a checkout the caller named", :aggregate_failures do
    forward(%W[Work.plan! checkout.value=#{main}])
    forward(%W[Work.plan! checkout=#{main}])

    expect(calls.map { |call| call[2] }).to eq([%W[Work.plan! checkout.value=#{main}], %W[Work.plan! checkout=#{main}]])
  end

  it "adds no checkout to a command that takes none" do
    forward(%w[Work.plan! work.value=x], arguments: [{ path: "work.value" }])

    expect(calls.first[2]).to eq(%w[Work.plan! work.value=x])
  end

  it "runs here an aggregate the main checkout also keeps in Memory", :aggregate_failures do
    expect(forward(%w[Other.do!], group: "Other")).to be_nil
    expect(calls).to be_empty
  end

  it "runs here a query" do
    expect(forward(%w[Work.undone], asking: true)).to be_nil
  end

  it "refuses with HECKS_NO_FORWARD and runs nothing", :aggregate_failures do
    text, status = forward(%w[Work.plan!], env: { "HECKS_NO_FORWARD" => "1" })

    expect(text).to include("Tickets::Work", main)
    expect([status, calls]).to eq([Hecks::Adapters::Driving::ExitStatus::REFUSED, []])
  end

  it "refuses a line that was already forwarded instead of forwarding it again", :aggregate_failures do
    text, = forward(%w[Work.plan!], env: { "HECKS_FORWARDED" => "1" })

    expect(text).to include("refused")
    expect(calls).to be_empty
  end

  it "refuses, not loses the write, when the main checkout's stores cannot be read", :aggregate_failures do
    unreadable = ->(_root) { raise Hecks::Adapters::Driving::LedgerStores::Unreadable, "the main checkout did not report its stores" }
    text, status = described_class.call(plan, %w[Work.plan!], err, directory: worktree, stores: unreadable, runner: runner)

    expect(text).to include("did not report its stores", "Run it from the main checkout")
    expect([status, calls]).to eq([Hecks::Adapters::Driving::ExitStatus::REFUSED, []])
  end

  it "refuses when the main checkout has no launcher to run the write in" do
    FileUtils.rm(File.join(main, "exe/hecks"))

    expect(forward(%w[Work.plan!]).first).to include("has no exe/hecks")
  end

  it "reports a run a signal ended as 128 plus the signal" do
    killed = ["", "", instance_double(Process::Status, exitstatus: nil, termsig: 15)]
    result = described_class.call(plan, %w[Work.plan!], err, directory: worktree, stores: stores, runner: ->(*) { killed })

    expect(result.last).to eq(143)
  end
end
