require "spec_helper"
require "fileutils"
require "tmpdir"

# Watching a lane through the launcher: `hecks promotion_run.watch` faults a lane that has stood
# behind the lane it follows for longer than its `Lane` row allows (`stable`: 4 hours), and the
# fault files a finding, one a day under its alert key. The remote, the checks and the clock are
# fakes over a scratch checkout, so nothing is fetched, asked or filed on GitHub.
RSpec.describe "watching a lane" do
  let(:now) { Time.utc(2026, 10, 6, 12, 0, 0) }
  let(:root) { Dir.mktmpdir("hecks-lane-watch-spec") }

  # The remote as the watch reads it: each lane's head, and when the oldest commit `stable` lacks
  # was made, `behind` hours before now (nil when there is none).
  let(:repo) do
    Class.new do
      def initialize(oldest, chain) = (@oldest = oldest) && (@chain = chain)
      def remote_head(ref, chdir: nil) = ref.delete_prefix("refs/heads/") == "main" ? "a" * 40 : "b" * 40
      def capture(*, chdir: nil) = nil
      def oldest_commit_time(_older, _newer, chdir: nil) = @oldest
      def recent_commits(_newer, older: nil, limit: 25, chdir: nil) = @chain
      def ancestor?(_older, _newer, chdir: nil) = true
    end
  end

  let(:checks) do
    Class.new do
      def initialize(states, by_commit)
        @states = states
        @by_commit = by_commit
      end

      def states(commit:, names:)
        standing = @states.merge(@by_commit.fetch(commit, {}))
        names.to_h { |name| [name, standing.fetch(name, :passed)] }
      end
    end
  end

  before do
    File.write(File.join(root, "hecks.gemspec"), "")
    FileUtils.mkdir_p(File.join(root, "lib"))
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
    Hecks::Adapters::Codebase::Tree.root = root
    Hecks::Adapters::Codebase::Promotion.clock = -> { now }
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
    %i[git checks clock].each { |name| Hecks::Adapters::Codebase::Promotion.public_send("#{name}=", nil) }
    FileUtils.remove_entry(root)
  end

  def launch(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  # Watches `stable` while its oldest unpromoted commit is `hours` old; nil hours is nothing to promote.
  # `world` is `states:` for every commit, `chain:` for main's commits above stable (newest first) and
  # `by_commit:` for the checks of one commit.
  def watch(run, hours:, key: "stable-lag-2026-10-06", lane: "stable", **world)
    stand_in(hours && (now - (hours * 3600)).to_i, world)
    launch("promotion_run.watch", "run=#{run}", "lane=#{lane}", "alert_key=#{key}")
    launch("promotion_run.promotion_outcome", "run=#{run}").first
  end

  def stand_in(oldest, world)
    Hecks::Adapters::Codebase::Promotion.git = repo.new(oldest, world.fetch(:chain, ["a" * 40]))
    Hecks::Adapters::Codebase::Promotion.checks = checks.new(world.fetch(:states, {}), world.fetch(:by_commit, {}))
  end

  def open_findings = JSON.parse(launch("tickets", "finding.open").first).map { |row| row.dig("finding", "value") }

  it "completes a lane that is behind by less than its Lane row allows, and files nothing", :aggregate_failures do
    out = watch("on-time", hours: 3)

    expect(out).to include('"status": "completed"', "stable is on time: 3h behind, 4h allowed")
    expect(open_findings).to be_empty
  end

  it "completes a lane with nothing to promote, however long since its last promotion" do
    expect(watch("level", hours: nil)).to include('"status": "completed"', "0h behind")
  end

  it "faults a lane that is late, naming how late and what main is waiting on", :aggregate_failures do
    out = watch("late", hours: 6, states: { "rspec_rust_io" => :failed })

    expect(out).to include('"status": "faulted"', "stable has stood 6h behind main (its Lane row allows 4h)")
    expect(out).to include("failed: rspec_rust_io")
  end

  it "says a promotion should have run when main is green and the lane is still late" do
    expect(watch("green-late", hours: 5)).to include("every required check passed on aaaaaaa")
  end

  # The age is the wait for something to land, and the reason tells a pipeline that is working from
  # one that is stuck: only a certified commit the lane has not reached means promotion is broken.
  it "calls a late lane stuck when an older commit is certified though the head is red", :aggregate_failures do
    older = "9" * 40
    out = watch("stuck", hours: 6, chain: ["a" * 40, older], by_commit: { "a" * 40 => { "rspec" => :failed } })

    expect(out).to include('"status": "faulted"', "every required check passed on 9999999, so a promotion should have run")
  end

  it "calls a late lane red, not stuck, when no recent commit is certified", :aggregate_failures do
    out = watch("red", hours: 6, chain: ["a" * 40, "9" * 40], states: { "rspec" => :failed })

    expect(out).to include("failed: rspec")
    expect(out).not_to include("a promotion should have run")
  end

  it "says the lane is waiting, not stuck, while the head's checks are still running" do
    out = watch("running", hours: 6, states: { "rspec" => :pending })

    expect(out).to include("waiting on: rspec")
  end

  it "files a finding for a late lane, under its alert key" do
    watch("late-finding", hours: 6)

    expect(open_findings).to eq(["stable-lag-2026-10-06"])
  end

  it "files one finding a day: the same alert key again is the same finding" do
    watch("first-hour", hours: 6)
    watch("second-hour", hours: 7)

    expect(open_findings).to eq(["stable-lag-2026-10-06"])
  end

  it "files a new finding the next day" do
    watch("monday", hours: 6)
    watch("tuesday", hours: 30, key: "stable-lag-2026-10-07")

    expect(open_findings).to contain_exactly("stable-lag-2026-10-06", "stable-lag-2026-10-07")
  end

  it "faults a lane no row follows another lane, and files no finding", :aggregate_failures do
    out = watch("main-lane", hours: 6, lane: "main")

    expect(out).to include('"status": "faulted"', "is not a Lane row that follows another lane")
    expect(open_findings).to be_empty
  end
end
