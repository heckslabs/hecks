require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "hecks/hecks/adapters/red_flag_kick"
require "hecks/hecks/adapters/red_flag_marker"

# A flag that has stood too long with no fix landed kicks the push batch off main: every
# first-parent commit since the last green head is reverted, newest first, on a red-kick branch
# that lands as a red row's fix, and the batch is filed as a Work row to land again. Every example
# builds its own repository; the landing and the filing are stand-ins that record what they were
# handed.
RSpec.describe Hecks::Adapters::RedFlagKick do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-red-kick")) }
  let(:repo) { File.join(dir, "main") }
  let(:marker) { Hecks::Adapters::RedFlagMarker.new(File.join(repo, ".git"), clock: -> { Time.utc(2026, 11, 2, 20, 31, 0) }) }
  let(:landed) { [] }
  let(:filed) { [] }

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
    # The reverter commits with the repository's own identity, which a CI runner lacks.
    git("config", "user.name", "t")
    git("config", "user.email", "t@t")
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

  def kick(force: false, now: Time.utc(2026, 11, 2, 23, 0, 0), **tune)
    lander = ->(branch, tree) { landed << [branch, git("rev-parse", "HEAD", chdir: tree)] }
    filer = ->(flag, batch, _branch) { filed << batch and "reland-#{flag["id"]}" }
    described_class.new(marker, repo, clock: -> { now }, kick_after: 60, lander: lander, filer: filer, **tune).run(force: force)
  end

  def tree_of(sha) = git("rev-parse", "#{sha}^{tree}")

  before { build_repo }

  it "reverts the batch since the last green head, newest first, onto a red-kick branch", :aggregate_failures do
    raise_flag
    kicked = kick

    expect(kicked[:reverted]).to eq([@merge, @bad])
    expect(tree_of(landed.first.last)).to eq(tree_of(@green))
  end

  it "lands the branch as a red row's fix and files the batch as a Work row", :aggregate_failures do
    raise_flag
    kicked = kick

    expect(landed.first.first).to eq("red-kick-#{marker.read["id"]}")
    expect(filed).to eq([[@merge, @bad]])
    expect(marker.read["kicked"]).to include("row" => kicked[:row], "reverted" => [@merge, @bad])
  end

  it "leaves main where it was: the revert is the fixer's to land" do
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
    expect { kick }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /already kicked to red-kick-/)
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
