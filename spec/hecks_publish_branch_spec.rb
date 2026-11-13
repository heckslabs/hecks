require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_publish")

# Publishing a worktree's branch: the git adapter, run against a stand-in runner, so no push
# reaches a remote. The stand-in answers the reads a publish makes and records each push it makes.
RSpec.describe "publishing a branch to origin" do
  # Answers the reads `GitPublish` makes and records the pushes, without running git.
  class PublishStandIn
    attr_reader :pushes

    def initialize(ahead:, remote_branch: true, push_ok: true)
      @ahead = ahead
      @remote_branch = remote_branch
      @push_ok = push_ok
      @pushes = []
    end

    def capture(*args, chdir: nil)
      return push(args) if args.first == "push"
      return answer(chdir) if args.include?("--show-toplevel")
      return answer("abc1234") if args.include?("--short")
      return @remote_branch ? answer("sha") : answer("", "", status: 1) if args.include?("--verify")

      answer(@ahead.to_s)
    end

    private

    def push(args)
      @pushes << args
      return answer("", "To origin: pushed") if @push_ok

      answer("", "! [rejected] work-a -> work-a (non-fast-forward)", status: 1)
    end

    def answer(out, err = "", status: 0)
      Hecks::Adapters::Shell::Result.new(out, err, Struct.new(:success?, :exitstatus).new(status.zero?, status))
    end
  end

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-publish")) }
  let(:runner) { PublishStandIn.new(ahead: 2) }

  after { FileUtils.remove_entry(dir) }

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def publish(git: runner, branch: "work-a")
    Hecks::Adapters::GitPublish.new(git: git).push(checkout: dir, branch: branch)
  end

  it "pushes the branch under its own name, with no force flag" do
    publish
    expect(runner.pushes).to eq([["push", "origin", "refs/heads/work-a:refs/heads/work-a"]])
  end

  it "answers the sha it published and the remote's answer" do
    expect(publish).to include(sha: { value: "abc1234" }, report: { value: a_string_including("To origin: pushed") })
  end

  it "refuses main, and pushes nothing", :aggregate_failures do
    expect { publish(branch: "main") }.to raise_error(failure, /main is never published/)
    expect(runner.pushes).to be_empty
  end

  it "refuses a branch with no commits the remote lacks, and pushes nothing", :aggregate_failures do
    expect { publish(git: PublishStandIn.new(ahead: 0)) }.to raise_error(failure, /nothing to publish/)
    expect(runner.pushes).to be_empty
  end

  it "refuses a push the remote rejects, with the remote's reason" do
    rejecting = PublishStandIn.new(ahead: 1, push_ok: false)
    expect { publish(git: rejecting) }.to raise_error(failure, /cannot publish work-a: .*non-fast-forward/)
  end
end
