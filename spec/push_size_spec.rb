require "spec_helper"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/dispatching"

# How big a push is: the size class in the `push_rehearsal.due` line, the title of the `push-due`
# row, the order the dispatch fill plans it in, the train's report line, and that no size refuses a
# push. Temp repositories with a local bare remote; the clock is injected and the registry stubbed.
RSpec.describe Hecks::Adapters::PushSize, :io do
  let(:scratch) { Dir.mktmpdir("hecks-push-size") }
  let(:work) { File.join(scratch, "work") }
  let(:limits) { { commits: 15, hours: 6.0, urgent_commits: 40 } }
  let(:now) { Time.at(1_800_000_000) }
  let(:clock) { instance_double(Time.singleton_class, now: now) }

  def git(*args, dir: work, **env)
    ident = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test", "GIT_COMMITTER_NAME" => "A",
              "GIT_COMMITTER_EMAIL" => "a@x.test" }.merge(env)
    out, err, status = Open3.capture3(ident, "git", *args, chdir: dir)
    raise "git #{args.join(" ")}: #{err}" unless status.success?

    out.strip
  end

  # Makes `count` commits, the first stamped `stamp`.
  def commits(count, stamp: now.to_i)
    count.times do |index|
      @made = (@made || 0) + 1
      File.write(File.join(work, "f#{@made}"), index.to_s)
      git("add", "-A")
      date = { "GIT_AUTHOR_DATE" => "#{stamp} +0000", "GIT_COMMITTER_DATE" => "#{stamp} +0000" }
      git("commit", "-q", "-m", "c#{index}", **date)
    end
  end

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commits(1)
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  def line = Hecks::Adapters::GitRehearsal::Due.new(Hecks::Adapters::Git.new, work, limits: limits, clock: clock).report

  def title(ahead) = described_class.title("a push of main is due", ahead, limits)

  it "keeps the plain line under the commit threshold", :aggregate_failures do
    commits(3, stamp: now.to_i - 3600)

    expect(line).to start_with("push due: yes; 3 commit(s) ahead of origin/main; oldest unpushed 1.0 hours old; last quick")
    expect(line).not_to include("PUSH NOW")
  end

  it "keeps the plain line between the hour minimum and the commit threshold", :aggregate_failures do
    commits(3, stamp: now.to_i - (7 * 3600))

    expect(line).to include("oldest unpushed 7.0 hours old")
    expect(line).not_to include("PUSH NOW")
  end

  it "says push due: no when main is level" do
    expect(line).to start_with("push due: no; main is level with origin/main")
  end

  it "says PUSH NOW once the commits pass the threshold" do
    commits(16)

    expect(line).to include("hours old; PUSH NOW: 16 commits is over the 15 you set (urgent at 40); last quick")
  end

  it "says the push is urgent past urgent_commits" do
    commits(41)

    expect(line).to include("URGENT PUSH NOW: 41 commits is over the 15 you set (urgent at 40)")
  end

  it "titles the push-due row by size class", :aggregate_failures do
    expect(title(3)).to eq("a push of main is due")
    expect(title(16)).to eq("a push of main is due, 16 commits")
    expect(title(41)).to eq("URGENT: a push of main is due, 41 commits")
  end

  it "reads the thresholds from the world, else the defaults", :aggregate_failures do
    world = instance_double(Hecks::Bluebook::World, for_verb: { commits: 5, hours: 2, urgent_commits: 9 })
    registry = instance_double(Hecks::Runtime::Registry, world: world)

    expect(described_class.thresholds(registry)).to eq({ commits: 5, hours: 2.0, urgent_commits: 9 })
    expect(described_class.thresholds(nil)).to eq({ commits: 15, hours: 6.0, urgent_commits: 40 })
  end

  describe "the dispatch fill" do
    def row(key, title) = Hecks::Adapters::Dispatching::Plan::Row.new(key: key, title: title, detail: "", area: [])

    def rows(pushing)
      Hecks::Adapters::Dispatching::Rows.new(nil).tap do |rows|
        allow(rows).to receive(:rows).with("planned").and_return([[1, row("later", "later")], [2, pushing]])
      end
    end

    it "plans an urgent push-due row first" do
      due = row("push-due", "URGENT: a push of main is due, 41 commits")

      expect(rows(due).planned.map(&:key)).to eq(%w[push-due later])
    end

    it "leaves a plain push-due row in plan order" do
      plain = row("push-due", "a push of main is due")

      expect(rows(plain).planned.map(&:key)).to eq(%w[later push-due])
    end
  end

  describe "the train" do
    def train = Hecks::Adapters::GitTrain.new(mint: instance_double(Hecks::Adapters::GitTrain::MintStep))

    it "reports the size before it pushes", :aggregate_failures do
      commits(41)
      adapter = train.tap { |t| t.instance_variable_set(:@checkout, work) }

      expect(adapter.send(:push_size, {})).to eq(
        "pushing 41 commits; URGENT PUSH NOW: 41 commits is over the 15 you set (urgent at 40)"
      )
    end

    it "never refuses a push, at any size" do
      commits(60)
      carriage = Hecks::Adapters::GitTrain::Carriage.new(Hecks::Adapters::Git.new, work, branch: "main", remote: "origin")
      answer = carriage.under_hold.carry(git("rev-parse", "main"))

      expect(answer.dig(:outcome, :value)).to eq("pushed")
    end
  end

  it "prints the thresholds in hecks config", :aggregate_failures do
    domain = { value: File.join(InMemoryDomain::ROOT, "lib/hecks/hecks") }
    text = Hecks::Adapters::SettingsReading.new.settings(domain: domain).fetch(:text)

    expect(text).to include("push nudge: 15 commits or 6.0 hours, urgent at 40 commits")
  end
end
