require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_rebase")

# Rebasing a worktree's branch: the git adapter, run against a stand-in runner, so no rebase
# happens. The stand-in holds the conflicted paths, clears one when it is staged, and records each
# git call it is asked.
RSpec.describe "rebasing a branch onto a base" do
  # Answers the git calls `GitRebase` makes, from the conflicts and the dirty listing it was given.
  class RebaseStandIn
    attr_reader :calls

    def initialize(conflicts: [], dirty: "")
      @conflicts = conflicts.dup
      @dirty = dirty
      @calls = []
    end

    def capture(*args, chdir: nil)
      @calls << args
      reply(args, chdir)
    end

    private

    def reply(args, dir)
      return text(locate(args, dir)) if args.intersect?(%w[--show-toplevel list --git-path])
      return text(@dirty) if args.first == "status"
      return text(@conflicts.join("\n")) if args.first == "diff"
      return outcome(args) if args.include?("rebase")

      stage(args)
    end

    def locate(args, dir)
      return dir if args.include?("--show-toplevel")
      return worktrees(dir) if args.include?("list")

      "#{dir}/.git/#{args.last}"
    end

    def outcome(args)
      return text("") if args.include?("--abort") || @conflicts.empty?

      text("", "CONFLICT (content)", success: false)
    end

    def stage(args)
      @conflicts.delete(args.last) if args.first == "add"
      text(args.include?("--short") ? "abc1234" : "")
    end

    def worktrees(repo)
      "worktree #{repo}\nHEAD 111\nbranch refs/heads/main\n\n" \
        "worktree #{repo}/.claude/worktrees/work-a\nHEAD 222\nbranch refs/heads/work-a\n"
    end

    def text(out, stderr = "", success: true)
      Hecks::Adapters::Shell::Result.new(out, stderr, Struct.new(:success?, :exitstatus).new(success, success ? 0 : 1))
    end
  end

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-rebase")) }
  let(:runner) { RebaseStandIn.new }

  after { FileUtils.remove_entry(dir) }

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def rebase(git: runner, **overrides)
    held = { checkout: dir, branch: "work-a", onto: "origin/main" }.merge(overrides)
    Hecks::Adapters::GitRebase.new(git: git).replay(**held)
  end

  it "rebases the branch onto the base and answers the sha it stands on" do
    expect(rebase).to include(sha: { value: "abc1234" }, report: { value: a_string_including("onto origin/main") })
  end

  it "refuses main, and starts no rebase", :aggregate_failures do
    expect { rebase(branch: "main") }.to raise_error(failure, /main is never rebased/)
    expect(runner.calls.none? { |call| call.include?("rebase") }).to be(true)
  end

  it "refuses a base that is the branch itself" do
    expect { rebase(onto: "work-a") }.to raise_error(failure, /never rebased onto itself/)
  end

  it "refuses a branch checked out in no worktree" do
    expect { rebase(branch: "work-b") }.to raise_error(failure, /checked out in no worktree/)
  end

  it "refuses a dirty checkout by name, and starts no rebase", :aggregate_failures do
    dirty = RebaseStandIn.new(dirty: " M lib/a.rb")
    expect { rebase(git: dirty) }.to raise_error(failure, /has uncommitted changes/)
    expect(dirty.calls.none? { |call| call.include?("rebase") }).to be(true)
  end

  it "stops on a conflict nobody named, aborts, and lists each path with its sides", :aggregate_failures do
    conflicted = RebaseStandIn.new(conflicts: %w[lib/a.rb lib/b.rb])
    expect { rebase(git: conflicted, resolve: "lib/a.rb=ours") }
      .to raise_error(failure, %r{lib/a\.rb \(ours is origin/main, theirs is work-a\); lib/b\.rb .*nothing changed})
    expect(conflicted.calls).to include(["rebase", "--abort"])
  end

  it "stops on a conflict with no resolve, naming the file" do
    expect { rebase(git: RebaseStandIn.new(conflicts: ["lib/a.rb"])) }.to raise_error(failure, %r{conflicts in lib/a\.rb})
  end

  it "takes the named side of each conflicted path, stages it and continues", :aggregate_failures do
    named = RebaseStandIn.new(conflicts: ["lib/a.rb"])
    expect(rebase(git: named, resolve: "lib/a.rb=theirs")[:report][:value]).to include("settled lib/a.rb")
    expect(named.calls).to include(["checkout", "--theirs", "--", "lib/a.rb"], ["add", "--", "lib/a.rb"])
  end

  it "refuses a resolve pair that names no side" do
    expect { rebase(resolve: "lib/a.rb=both") }.to raise_error(failure, /resolve takes path=ours or path=theirs/)
  end
end
