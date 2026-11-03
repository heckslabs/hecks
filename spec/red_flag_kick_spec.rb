require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "hecks/hecks/adapters/red_flag_kick"
require "hecks/hecks/adapters/red_flag_marker"

# A flag that goes up kicks the push batch off main: every first-parent commit since the last green
# head is reverted, newest first, on a red-main-<cause> branch, finished onto main and boarded, and
# a red-* Work item is filed for one coder. Every example builds its own repository; the
# steps are stand-ins that record what they were handed and touch neither GitHub nor the train.
RSpec.describe Hecks::Adapters::RedFlagKick do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-red-kick")) }
  let(:repo) { File.join(dir, "main") }
  let(:marker) { Hecks::Adapters::RedFlagMarker.new(File.join(repo, ".git"), clock: -> { Time.utc(2026, 11, 2, 20, 31, 0) }) }
  let(:calls) { [] }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(file, message)
    File.write(File.join(repo, file), message)
    git("add", file)
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD")
  end

  # Main: a green head, then a plain commit and a merge on top of it, the batch a kick reverts.
  def build_repo
    FileUtils.mkdir_p(repo)
    git("init", "-q", "-b", "main")
    identify
    @green = commit("a.txt", "green")
    @bad = commit("b.txt", "bad")
    git("checkout", "-q", "-b", "feature")
    commit("c.txt", "feature")
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
    @merge = git("rev-parse", "HEAD")
  end

  def raise_flag(last_green: @green)
    marker.raise!(commit: @merge, run: { ci_run: "41540218609", jobs: "rspec_impl / rspec_shard (8)", last_green: last_green })
  end

  # The reverter commits with the repository's own identity, which a CI runner lacks.
  def identify
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
  end

  # One stand-in per step: it records the keywords it was handed and answers as the real step would.
  def record(step, **args) = calls << [step, args]

  def stand_ins
    %i[board plan dispatch].to_h { |step| [step, ->(**args) { record(step, **args) }] }.merge(
      land:   ->(**args) { record(:land, **args, head: git("rev-parse", "HEAD", chdir: args[:checkout])) },
      brief:  ->(**args) { record(:brief, **args) && "brief for #{args[:work]}" },
      retire: ->(**args) { record(:retire, **args) && git("worktree", "remove", "--force", args[:checkout]) }
    )
  end

  def kick(force: false, now: Time.utc(2026, 11, 2, 23, 0, 0), effects: stand_ins, **tune)
    described_class.new(marker, repo, clock: -> { now }, kick_after: 60, effects: effects, **tune).run(force: force)
  end

  def steps = calls.map(&:first)

  def args_of(step) = calls.find { |name, _| name == step }.last

  def tree_of(sha) = git("rev-parse", "#{sha}^{tree}")

  before { build_repo }

  it "reverts the batch since the last green head, newest first, onto a red-main branch", :aggregate_failures do
    raise_flag
    kicked = kick

    expect(kicked[:reverted]).to eq([@merge, @bad])
    expect(kicked[:branch]).to eq("red-main-#{marker.read["id"]}")
    expect(tree_of(args_of(:land)[:head])).to eq(tree_of(@green))
  end

  it "finishes the branch onto main, boards main, files a red row and dispatches one coder on its brief", :aggregate_failures do
    raise_flag
    kick

    expect(steps).to eq(%i[land board plan brief dispatch retire])
    expect(args_of(:land)).to include(branch: "red-main-#{marker.read["id"]}", confirm: true)
    expect(args_of(:dispatch)).to include(brief: "brief for red-#{marker.read["id"]}", repo: repo)
  end

  it "names the failing jobs and the CI run in the Work row it files", :aggregate_failures do
    raise_flag
    kick

    expect(args_of(:plan)).to include(work: "red-#{marker.read["id"]}")
    expect(args_of(:plan)[:detail]).to include("CI run 41540218609", "rspec_impl / rspec_shard (8)")
  end

  it "records the kick on the flag, naming the branch, the reverted commits and the row", :aggregate_failures do
    raise_flag
    kicked = kick

    expect(marker.read["kicked"]).to include("reverted" => [@merge, @bad], "row" => kicked[:row])
  end

  it "leaves main where it was until the landing finishes it", :aggregate_failures do
    raise_flag
    kick

    expect(git("rev-parse", "main")).to eq(@merge)
  end

  it "refuses before kick_after_minutes, and kicks at once when forced", :aggregate_failures do
    raise_flag

    expect { kick(now: Time.utc(2026, 11, 2, 20, 50, 0)) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /stood 19 min, less than kick_after_minutes \(60\)/)
    expect(kick(now: Time.utc(2026, 11, 2, 20, 50, 0), force: true)[:reverted].size).to eq(2)
  end

  it "refuses when a fix has already landed, naming its tip" do
    raise_flag
    marker.fixed!(tip: @merge, branch: "red-ci-rspec")

    expect { kick }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /a fix is already landed at #{@merge[0, 10]}/)
  end

  it "refuses when no flag stands, and refuses a second kick", :aggregate_failures do
    expect { kick }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no red flag stands/)
    raise_flag
    kick
    expect { kick }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /already kicked to red-main-/)
  end

  it "refuses a batch that holds a release commit, and leaves main and the branches as they were", :aggregate_failures do
    commit("r.txt", "release\n\nRelease-Approved-By: owner")
    raise_flag

    expect { kick }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /is a release commit; releases are the owner's/)
    expect(git("branch", "--list", "red-main-*")).to eq("")
  end

  it "refuses while a session is already fixing the flag, so the batch is not reverted", :aggregate_failures do
    raise_flag
    marker.check_in!(session: "s1", taking: "red-ci-rspec-shards")

    expect { kick }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /red-ci-rspec-shards is already being fixed/)
    expect(calls).to be_empty
  end

  it "refuses when the landing refuses, and leaves no branch or worktree behind", :aggregate_failures do
    raise_flag
    refusing = stand_ins.merge(land: ->(**) { raise Hecks::Adapters::ConsoleCapture::Failure, "queue busy" })

    expect { kick(effects: refusing) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /queue busy/)
    expect(git("branch", "--list", "red-main-*")).to eq("")
    expect(git("rev-parse", "main")).to eq(@merge)
  end

  it "asks GitHub for the last green head when the flag recorded none" do
    raise_flag(last_green: "")
    gh = ->(argv, **) { [true, JSON.generate(argv.include?("success") ? [{ "headSha" => @green }] : [])] }

    expect(kick(runner: gh)[:reverted]).to eq([@merge, @bad])
  end

  it "refuses a last green head that is not on main" do
    raise_flag(last_green: "0b49c62c2c0b49c62c2c0b49c62c2c0b49c62c2c")

    expect { kick }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /last green head 0b49c62c2c is not on main/)
  end
end
