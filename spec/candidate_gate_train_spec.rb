require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The push train through the candidate gate (ADR 0181), against a local bare repository and a clone
# of it: off, a boarding pushes main as before; on, it pushes the candidate ref and not main,
# refuses a second boarding while one is in flight, and promotes at once a commit whose tree CI
# already passed on. GitHub is a fake that answers the green runs; no hook runs here.
RSpec.describe "the push train through the candidate gate", :io do
  let(:scratch) { Dir.mktmpdir("hecks-candidate-gate") }
  let(:work) { File.join(scratch, "work") }
  let(:green) { [] }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, text: name)
    File.write(File.join(work, name), text)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  # A fake GitHub: every run list answers the commits in `green` as green heads.
  def github(argv, **)
    return [true, JSON.generate(green.map { |sha| { "headSha" => sha } })] if argv[1..2] == %w[run list]

    [false, "unexpected #{argv.join(" ")}"]
  end

  def still_mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape f30dcb did not move")

  def train = Hecks::Adapters::GitTrain.new(mint: still_mint, runner: method(:github))

  def carry = train.carry(checkout: { value: work })

  def remote(ref) = git("ls-remote", "origin", ref).split.first

  def marker = JSON.parse(File.read(File.join(work, ".git", Hecks::Adapters::CandidateMarker::FILE)))

  def gate_on = git("config", Hecks::Adapters::CandidateGate::CONFIG, "true")

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  it "pushes main as before while the gate is off", :aggregate_failures do
    commit("second")

    expect(carry).to include(outcome: { value: "pushed" })
    expect(remote("refs/heads/main")).to eq(git("rev-parse", "main"))
  end

  it "pushes the candidate ref and not main while the gate is on", :aggregate_failures do
    gate_on
    commit("second")

    expect(carry).to include(outcome: { value: "queued" }, boarded: { value: git("rev-parse", "main") })
    expect(remote("refs/heads/candidate")).to eq(git("rev-parse", "main"))
    expect(remote("refs/heads/main")).to eq(git("rev-parse", "main~1"))
  end

  it "records the queued candidate with its base and its commits", :aggregate_failures do
    gate_on
    commit("second")
    carry

    expect(marker).to include("sha" => git("rev-parse", "main"), "base" => git("rev-parse", "main~1"), "state" => "queued")
    expect(marker["commits"]).to eq(1)
  end

  it "refuses a second boarding while a candidate is in flight, naming it" do
    gate_on
    commit("second")
    carry
    commit("third")

    expect { carry }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /candidate \h{9} is in flight: run not yet known/)
  end

  # Queues "second" as the candidate, lands "third", and boards again; answers the queued commit.
  def refused_second_boarding
    gate_on
    commit("second")
    queued = carry.dig(:boarded, :value)
    commit("third")
    carry
  rescue Hecks::Adapters::ConsoleCapture::Failure
    queued
  end

  it "pushes nothing when it refuses the second boarding" do
    queued = refused_second_boarding

    expect(remote("refs/heads/candidate")).to eq(queued)
  end

  # Queues "second" as the candidate and promotes it onto the remote's main, as the workflow does.
  def promoted_elsewhere
    gate_on
    commit("second")
    git("push", "-q", "origin", "#{carry.dig(:boarded, :value)}:refs/heads/main")
    commit("third")
  end

  it "boards again once the candidate was promoted onto the remote's main", :aggregate_failures do
    promoted_elsewhere

    expect(carry).to include(outcome: { value: "queued" })
    expect(remote("refs/heads/candidate")).to eq(git("rev-parse", "main"))
  end

  # A commit whose tree is the one CI passed on at "second".
  def same_tree_as_green
    gate_on
    commit("second")
    green << git("rev-parse", "main")
    git("commit", "-q", "--allow-empty", "-m", "same tree again")
  end

  it "promotes a commit whose tree CI already passed on straight to main, with no run", :aggregate_failures do
    same_tree_as_green

    expect(carry).to include(outcome: { value: "pushed" }, pushed: { value: git("rev-parse", "main") })
    expect(remote("refs/heads/main")).to eq(git("rev-parse", "main"))
    expect(marker).to include("state" => "promoted")
  end

  it "says the tree match in the promotion's report" do
    same_tree_as_green

    expect(carry.dig(:report, :value)).to include("promoted to origin/main with no CI run")
  end

  it "rides on an earlier push that already carried the boarded commit" do
    gate_on

    expect(carry).to include(outcome: { value: "carried" })
  end
end
