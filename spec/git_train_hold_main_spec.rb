require "spec_helper"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# Under the push hold, local main must not move between the final check and the push: the carriage
# compares it with the commit the check ran on and refuses by name.
# Temp repositories, a local bare remote.
RSpec.describe Hecks::Adapters::GitTrain::Carriage, :io do
  let(:scratch) { Dir.mktmpdir("hecks-hold-main") }
  let(:work) { File.join(scratch, "work") }

  def git(*args, dir: work)
    env = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test", "GIT_COMMITTER_NAME" => "A",
"GIT_COMMITTER_EMAIL" => "a@x.test" }
    out, err, status = Open3.capture3(env, "git", *args, chdir: dir)
    raise "git #{args.join(" ")}: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  def carriage = described_class.new(Hecks::Adapters::Git.new, work, branch: "main", remote: "origin")

  def moved_error(checked, moved)
    "main moved from #{checked[0, 9]} to #{moved[0, 9]} during the push hold: board again"
  end

  def carry_after_a_move
    checked = git("rev-parse", "main")
    commit("second")
    [checked, git("rev-parse", "main"), -> { carriage.under_hold.carry(checked) }]
  end

  it "refuses by name when main moved during the hold" do
    checked, moved, attempt = carry_after_a_move

    expect(&attempt).to raise_error(Hecks::Adapters::ConsoleCapture::Failure, moved_error(checked, moved))
  end

  it "pushes nothing when it refuses" do
    checked, _moved, attempt = carry_after_a_move
    attempt.call rescue nil # rubocop:disable Style/RescueModifier

    expect(git("rev-parse", "origin/main")).to eq(checked)
  end
end
