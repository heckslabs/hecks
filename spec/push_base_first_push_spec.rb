require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/git_train"

# The commits a push counts from: the branch's remote tip, or `main` for a branch the remote has
# never had. A first push of a new branch counts from `main`, because the remote ref it would
# otherwise name does not exist yet.
RSpec.describe "the base a push is counted from", :io do
  let(:scratch) { File.realpath(Dir.mktmpdir("hecks-first-push")) }
  let(:repo) { File.join(scratch, "repo") }
  let(:origin) { File.join(scratch, "origin.git") }

  def git(*args, dir: repo)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(repo, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  # A train reading only the git port, with the checkout at `repo`; nothing else is consulted here.
  def train
    adapter = Hecks::Adapters::GitTrain.allocate
    adapter.instance_variable_set(:@git, Hecks::Adapters::Git.new)
    adapter.instance_variable_set(:@checkout, repo)
    adapter
  end

  def base_for(branch)
    train.send(:push_base, { branch: { value: branch }, remote: { value: "origin" } })
  end

  before do
    git("init", "-q", "-b", "main", repo, dir: scratch)
    git("config", "user.name", "A", dir: repo)
    git("config", "user.email", "a@example.test", dir: repo)
    commit("first")
    git("init", "-q", "--bare", origin, dir: scratch)
    git("remote", "add", "origin", origin)
    git("push", "-q", "origin", "main")
    git("checkout", "-q", "-b", "feat")
    commit("second")
  end

  after { FileUtils.remove_entry(scratch) }

  it "counts a branch the remote has never had from main" do
    expect(base_for("feat")).to eq("main")
  end

  it "counts a branch the remote already has from its remote tip" do
    git("push", "-q", "origin", "feat")

    expect(base_for("feat")).to eq("origin/feat")
  end
end
