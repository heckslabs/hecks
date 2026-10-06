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
      def initialize(oldest) = @oldest = oldest
      def remote_head(ref, chdir: nil) = ref.delete_prefix("refs/heads/") == "main" ? "a" * 40 : "b" * 40
      def capture(*, chdir: nil) = nil
      def oldest_commit_time(_older, _newer, chdir: nil) = @oldest
    end
  end

  let(:checks) do
    Class.new do
      def initialize(states) = @states = states
      def states(commit:, names:) = names.to_h { |name| [name, @states.fetch(name, :passed)] }
    end
  end

  before do
    File.write(File.join(root, "hecks.gemspec"), "")
    FileUtils.mkdir_p(File.join(root, "lib"))
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    Hecks::Adapters::Codebase::Tree.root = root
    Hecks::Adapters::Codebase::Promotion.clock = -> { now }
  end

  after do
    Hecks::Adapters::Codebase::Tree.root = nil
    %i[git checks clock].each { |name| Hecks::Adapters::Codebase::Promotion.public_send("#{name}=", nil) }
    FileUtils.remove_entry(root)
  end

  def launch(*argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  # Watches `stable` while its oldest unpromoted commit is `hours` old; nil hours is nothing to promote.
  def watch(run, hours:, key: "stable-lag-2026-10-06", lane: "stable", states: {})
    oldest = hours && (now - (hours * 3600)).to_i
    Hecks::Adapters::Codebase::Promotion.git = repo.new(oldest)
    Hecks::Adapters::Codebase::Promotion.checks = checks.new(states)
    launch("promotion_run.watch", "run=#{run}", "lane=#{lane}", "alert_key=#{key}")
    launch("promotion_run.promotion_outcome", "run=#{run}").first
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
