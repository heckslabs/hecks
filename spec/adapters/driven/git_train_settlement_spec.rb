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

  # The Hecks mint a boarding runs first, answering that the shape did not move.
  def still_mint = instance_double(described_class::MintStep, run: "the Hecks shape f30dcb did not move")

  # A fake `gh`: a PR opens, and auto-merge merges it at once, moving the remote's main as GitHub does.
  def gh(argv, **)
    case argv[1..2]
    when %w[pr create] then [true, "https://github.test/work/pull/1\n"]
    when %w[pr merge]
      sha = git("ls-remote", "origin", "refs/heads/#{argv[3]}").split.first
      git("push", "-q", "--no-verify", "origin", "#{sha}:refs/heads/main")
      [true, ""]
    else [false, "no PR"]
    end
  end

  def train = described_class.new(mint: still_mint, runner: method(:gh))

  def carry = train.carry(checkout: { value: work })

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

    expect(carry[:outcome]).to eq(value: "queued")
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

    expect(carry[:outcome]).to eq(value: "queued")
    expect(git("rev-parse", "HEAD", dir: work)).to eq(git("rev-parse", "origin/main", dir: work))
  end

  describe "the boarded branch only" do
    let(:git_adapter) { Hecks::Adapters::Git.new }

    def settlement = described_class::Settlement.new(git_adapter, work, branch: "main", remote: "origin")

    # A branch that diverged from its remote, and the commit it named at boarding.
    def diverged
      commit("local-only")
      push_elsewhere("remote-only")
      git("rev-parse", "main")
    end

    it "refuses a checkout that has another branch checked out, and moves nothing", :aggregate_failures do
      main = diverged
      git("checkout", "-q", "-b", "feature")

      expect { settlement.run(main) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /feature checked out, not main/)
      expect(git("rev-parse", "main")).to eq(main)
    end

    it "refuses a detached checkout" do
      main = diverged
      git("checkout", "-q", "--detach")

      expect { settlement.run(main) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /detached HEAD/)
    end

    it "refuses a checkout with staged files before it rebases", :aggregate_failures do
      main = diverged
      File.write(File.join(work, "first"), "edited")
      git("add", "first")

      expect { settlement.run(main) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /staged or modified/)
      expect(git("rev-parse", "main")).to eq(main)
    end

    it "refuses a branch that moved since boarding" do
      boarded = git("rev-parse", "main")
      commit("late")

      expect { settlement.run(boarded) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main moved since boarding/)
    end

    it "answers the rebased commit the carriage then carries" do
      commit("local-only")
      push_elsewhere("remote-only")

      expect(settlement.run(git("rev-parse", "main"))).to eq(git("rev-parse", "main"))
    end

    context "with a shape ledger to settle" do
      let(:ledger) { File.join(work, described_class::Settlement::LEDGER) }

      before do
        FileUtils.mkdir_p(File.dirname(ledger))
        File.write(ledger, "old")
        git("add", ".")
        git("commit", "-q", "-m", "ledger")
        script = File.join(scratch, "settle.sh")
        File.write(script, "#!/bin/sh\nprintf changed > #{ledger}\n")
        FileUtils.chmod("+x", script)
        stub_const("Hecks::Adapters::GitTrain::Settlement::SETTLE", [script].freeze)
      end

      it "refuses rather than sweep other staged files into the ledger commit", :aggregate_failures do
        git("config", "core.hooksPath", File::NULL)
        File.write(File.join(work, "other"), "staged")
        git("add", "other")

        expect { settlement.run(git("rev-parse", "main")) }
          .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /staged or modified/)
      end

      it "names the ledger path in its commit and sweeps in nothing else", :aggregate_failures do
        boarded = git("rev-parse", "main")
        settled = settlement.run(boarded)

        expect(settled).not_to eq(boarded)
        expect(git("show", "--name-only", "--format=", settled).lines.map(&:strip)).to eq([described_class::Settlement::LEDGER])
      end
    end
  end

  describe "the drift checks" do
    let(:git_adapter) { Hecks::Adapters::Git.new }
    let(:drift_checks) { [] }

    before do
      FileUtils.mkdir_p(File.join(work, "exe"))
      File.write(File.join(work, "exe", "hecks"), "")
    end

    def settle(checks)
      Hecks::Adapters::GitTrain::Settlement.new(git_adapter, work, branch: "main", remote: "origin", drift: checks)
                                           .run(git("rev-parse", "main"))
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
