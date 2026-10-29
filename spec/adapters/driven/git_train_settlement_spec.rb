require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The Train port's boarding before its carriage: a branch that has diverged from its remote is
# rebased onto it and carried, and a rebase that conflicts outside the shape ledger is aborted and
# reported by path. Against a local bare repository and clones of it.
RSpec.describe Hecks::Adapters::GitTrain, :io do
  let(:scratch) { Dir.mktmpdir("hecks-git-train-settle") }
  let(:work) { File.join(scratch, "work") }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, dir: work, text: name)
    File.write(File.join(dir, name), text)
    git("add", name, dir: dir)
    git("commit", "-q", "-m", name, dir: dir)
  end

  # A second clone that pushes on its own, as another machine would.
  def push_elsewhere(name, text: name)
    other = File.join(scratch, "other")
    git("clone", "-q", "-b", "main", File.join(scratch, "origin.git"), other, dir: scratch) unless File.directory?(other)
    commit(name, dir: other, text: text)
    git("push", "-q", "origin", "main", dir: other)
  end

  def carry = described_class.new.carry(checkout: { value: work })

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    git("config", "user.name", "A")
    git("config", "user.email", "a@example.test")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  it "rebases a diverged branch onto its remote, then carries it", :aggregate_failures do
    commit("local-only")
    push_elsewhere("remote-only")

    expect(carry[:outcome]).to eq(value: "pushed")
    expect(git("log", "--format=%s", "origin/main", dir: work)).to include("local-only", "remote-only")
    expect(git("rev-parse", "HEAD", dir: work)).to eq(git("rev-parse", "origin/main", dir: work))
  end

  it "aborts a rebase that conflicts outside the ledger, and says which path", :aggregate_failures do
    commit("shared", text: "local")
    push_elsewhere("shared", text: "remote")

    expect { carry }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /conflict in shared/)
    expect(File.exist?(File.join(work, ".git", "rebase-merge"))).to be(false)
    expect(File.exist?(File.join(work, ".git", "rebase-apply"))).to be(false)
  end

  it "carries a branch that is ahead only, without rebasing it", :aggregate_failures do
    commit("local-only")

    expect(carry[:outcome]).to eq(value: "pushed")
    expect(git("rev-parse", "HEAD", dir: work)).to eq(git("rev-parse", "origin/main", dir: work))
  end

  describe "the drift checks" do
    let(:git_adapter) { Hecks::Adapters::Git.new }
    let(:drift_checks) { [] }

    before do
      FileUtils.mkdir_p(File.join(work, "exe"))
      File.write(File.join(work, "exe", "hecks"), "")
    end

    def settle(checks)
      Hecks::Adapters::GitTrain::Settlement.new(git_adapter, work, branch: "main", remote: "origin", drift: checks).run
    end

    it "refuses the boarding when a drift check finds drift, and names the check" do
      checks = [["sh", "-c", "echo fine"], ["sh", "-c", "echo generated tree differs; exit 1"]]

      expect { settle(checks) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /generated tree differs/)
    end

    it "passes when every drift check is clean" do
      expect { settle([%w[sh -c true]]) }.not_to raise_error
    end
  end
end
