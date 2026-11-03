require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "hecks/hecks/adapters/red_flag_kick"
require "hecks/hecks/adapters/red_flag_marker"

# A flag that goes up rolls main back at once: main's tree is restored to the last green head's as
# one new commit on a red-main-<cause> branch, finished onto main and boarded, the flag is cleared
# because the restored tree is a tree CI already passed, and a red-* Work item is filed for one
# coder. Every example builds its own repository and its own origin under a temporary directory;
# the steps are stand-ins that record what they were handed and touch neither GitHub nor the
# train.
RSpec.describe Hecks::Adapters::RedFlagKick do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-red-kick")) }
  let(:repo) { File.join(dir, "main") }
  let(:marker) { Hecks::Adapters::RedFlagMarker.new(File.join(repo, ".git"), clock: -> { Time.utc(2026, 11, 2, 20, 31, 0) }) }
  let(:calls) { [] }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  # rm_rf, not remove_entry: a detached `git maintenance` may still hold a lock in the repository.
  after { FileUtils.rm_rf(dir) }

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

  # Main: a green head, then a plain commit and a merge on top of it, the batch a kick rolls back.
  def build_repo
    FileUtils.mkdir_p(repo)
    git("init", "-q", "-b", "main")
    git("config", "maintenance.auto", "false")
    git("config", "gc.auto", "0")
    identify
    @green = commit("a.txt", "green")
    @bad = commit("b.txt", "bad")
    @merge = merge_feature
    publish_origin
  end

  def merge_feature
    git("checkout", "-q", "-b", "feature")
    commit("c.txt", "feature")
    git("checkout", "-q", "main")
    git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
    git("rev-parse", "HEAD")
  end

  # The red batch is on origin, as it is when CI has run on it.
  def publish_origin
    git("init", "-q", "--bare", "-b", "main", File.join(dir, "origin.git"), chdir: dir)
    git("remote", "add", "origin", File.join(dir, "origin.git"))
    git("push", "-q", "origin", "main")
  end

  def raise_flag(last_green: @green)
    marker.raise!(commit: @merge, run: { ci_run: "41540218609", jobs: "rspec_impl / rspec_shard (8)", last_green: last_green })
  end

  # The restore commits with the repository's own identity, which a CI runner lacks.
  def identify
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
  end

  # One stand-in per step: it records the keywords it was handed and answers as the real step would.
  def record(step, **args) = calls << [step, args]

  def stand_ins
    %i[board plan dispatch eject lift].to_h { |step| [step, ->(**args) { record(step, **args) }] }.merge(
      land:   ->(**args) { land(args) },
      brief:  ->(**args) { record(:brief, **args) && "brief for #{args[:work]}" },
      retire: ->(**args) { record(:retire, **args) && git("worktree", "remove", "--force", args[:checkout]) }
    )
  end

  # The landing as the real one leaves main: the branch fast-forwarded onto it.
  def land(args)
    record(:land, **args, head: git("rev-parse", "HEAD", chdir: args[:checkout]))
    git("merge", "-q", "--ff-only", args[:branch])
  end

  def kick(effects: stand_ins, **tune)
    described_class.new(marker, repo, effects: effects, **tune).run
  end

  # Raises the flag, kicks, and answers the flag's id.
  def kicked_id
    raise_flag
    id = marker.read["id"]
    kick
    id
  end

  # A pre-commit hook that refuses every commit of the repository.
  def refuse_commits
    hook = File.join(repo, ".git/hooks/pre-commit")
    File.write(hook, "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, hook)
  end

  def steps = calls.map(&:first)

  def args_of(step) = calls.find { |name, _| name == step }.last

  def tree_of(sha) = git("rev-parse", "#{sha}^{tree}")

  before { build_repo }

  it "rolls the batch since the last green head back onto a red-main branch, newest first", :aggregate_failures do
    raise_flag
    kicked = kick

    expect(kicked[:reverted]).to eq([@merge, @bad])
    expect(kicked[:branch]).to eq("red-main-#{kicked[:flag]["id"]}")
    expect(tree_of(args_of(:land)[:head])).to eq(tree_of(@green))
  end

  it "adds one new commit on top of the red tip and rewrites nothing", :aggregate_failures do
    raise_flag
    kick

    expect(git("rev-list", "--count", "#{@merge}..main")).to eq("1")
    expect(git("log", "-1", "--format=%s", "main")).to start_with("Restore main to the last green tree")
    expect(git("merge-base", "--is-ancestor", @merge, "main")).to eq("")
  end

  it "finishes the branch onto main, boards main, files a red-* Work item and dispatches one coder", :aggregate_failures do
    id = kicked_id

    expect(steps).to eq(%i[land board plan brief dispatch retire eject lift])
    expect(args_of(:land)).to include(branch: "red-main-#{id}", confirm: true)
    expect(args_of(:dispatch)).to include(brief: "brief for red-#{id}", repo: repo)
  end

  it "names the failing jobs and the CI run in the Work item it files", :aggregate_failures do
    id = kicked_id

    expect(args_of(:plan)).to include(work: "red-#{id}")
    expect(args_of(:plan)[:detail]).to include("CI run 41540218609", "rspec_impl / rspec_shard (8)")
  end

  it "clears the flag at once, since the restored tree equals the green tree CI passed", :aggregate_failures do
    raise_flag
    kicked = kick

    expect(kicked[:restored]).to be(true)
    expect(marker.read).to be_nil
    expect(tree_of("main")).to eq(tree_of(@green))
  end

  it "refuses to board when local main holds a commit beyond the restore, and boards nothing", :aggregate_failures do
    raise_flag
    foreign = stand_ins.merge(land: ->(**args) { land(args) && commit("foreign.txt", "foreign") })

    expect { kick(effects: foreign) }.to raise_error(failure, %r{2 commits ahead of origin/main, not only the restore})
    expect(steps).not_to include(:board)
  end

  it "refuses when a fix has already landed, naming its tip" do
    raise_flag
    marker.fixed!(tip: @merge, branch: "red-ci-rspec")

    expect { kick }.to raise_error(failure, /a fix is already landed at #{@merge[0, 10]}/)
  end

  it "refuses when no flag stands" do
    expect { kick }.to raise_error(failure, /no red flag stands/)
  end

  it "refuses a second kick for the same flag" do
    raise_flag
    marker.kicked!(branch: "red-main-x", reverted: [@bad], work_item: "red-x")

    expect { kick }.to raise_error(failure, /already kicked to red-main-x/)
  end

  it "refuses a batch that holds a release commit, and leaves main and the branches as they were", :aggregate_failures do
    commit("r.txt", "release\n\nRelease-Approved-By: owner")
    git("push", "-q", "origin", "main")
    raise_flag

    expect { kick }.to raise_error(failure, /is a release commit; releases are the owner's/)
    expect(git("branch", "--list", "red-main-*")).to eq("")
  end

  it "refuses while a session is already fixing the flag, so the batch is not rolled back", :aggregate_failures do
    raise_flag
    marker.check_in!(session: "s1", taking: "red-ci-rspec-shards")

    expect { kick }.to raise_error(failure, /red-ci-rspec-shards is already being fixed/)
    expect(calls).to be_empty
  end

  it "refuses when the landing refuses, and leaves no branch or worktree behind", :aggregate_failures do
    raise_flag
    refusing = stand_ins.merge(land: ->(**) { raise failure, "queue busy" })

    expect { kick(effects: refusing) }.to raise_error(failure, /queue busy/)
    expect(git("branch", "--list", "red-main-*")).to eq("")
    expect(git("rev-parse", "main")).to eq(@merge)
  end

  it "refuses when the restore cannot be committed, and leaves no branch behind", :aggregate_failures do
    raise_flag
    refuse_commits

    expect { kick }.to raise_error(failure, /restoring #{@green[0, 10]} failed/)
    expect(git("branch", "--list", "red-main-*")).to eq("")
  end

  it "asks GitHub for the last green head when the flag recorded none" do
    raise_flag(last_green: "")
    gh = ->(argv, **) { [true, JSON.generate(argv.include?("success") ? [{ "headSha" => @green }] : [])] }

    expect(kick(runner: gh)[:reverted]).to eq([@merge, @bad])
  end

  it "refuses when no green head is recorded and GitHub names none" do
    raise_flag(last_green: "")
    gh = ->(_argv, **) { [true, "[]"] }

    expect { kick(runner: gh) }.to raise_error(failure, /last green head of main cannot be told/)
  end

  it "refuses a last green head that is not on main" do
    raise_flag(last_green: "0b49c62c2c0b49c62c2c0b49c62c2c0b49c62c2c")

    expect { kick }.to raise_error(failure, /last green head 0b49c62c2c is not on main/)
  end
end
