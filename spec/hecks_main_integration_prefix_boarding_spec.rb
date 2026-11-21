require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/main_integration/repository"
require "hecks/hecks/adapters/main_integration/prefix_boarding"

# Boarding the prefix of main from a worktree at the culprit's parent. The runner stands in for
# git and the train, so nothing is checked out or pushed.
RSpec.describe Hecks::Adapters::MainIntegration::PrefixBoarding do
  let(:dir) { Dir.mktmpdir }
  let(:repository) { instance_double(Hecks::Adapters::MainIntegration::Repository, checkout: checkout, first_parent: parent) }
  let(:calls) { [] }

  after { FileUtils.remove_entry(dir) }

  def failure = Hecks::Adapters::ConsoleCapture::Failure
  def culprit = "c" * 40
  def parent = "a" * 40
  def checkout = File.join(dir, "checkout")
  def base = File.join(dir, "wts")

  def runner(status: "pushed", accepted: true)
    lambda do |argv, chdir:|
      calls << [argv, chdir]
      next [true, ""] unless argv.include?("SendTrain.board!")

      [accepted, JSON.generate("state" => { "status" => status, "refusal" => "no" })]
    end
  end

  def boarding(**) = described_class.new(repository, runner: runner(**), base: base)
  def worktree = File.join(base, "prefix-board-#{culprit[0, 10]}")
  def board_call = calls.map(&:first).find { |argv| argv.include?("SendTrain.board!") }

  before do
    FileUtils.mkdir_p(File.join(checkout, "lib/x"))
    File.write(File.join(checkout, "lib/x/a.local.world"), "w")
  end

  it "adds a detached worktree at the culprit's parent and copies the local files" do
    boarding.board(culprit)
    expect(calls.first).to eq([["git", "worktree", "add", "--detach", worktree, parent], checkout])
  end

  it "copies the local world files into the worktree" do
    allow(FileUtils).to receive(:cp).and_call_original
    boarding.board(culprit)
    expect(FileUtils).to have_received(:cp).with(File.join(checkout, "lib/x/a.local.world"),
                                                 File.join(worktree, "lib/x/a.local.world"))
  end

  it "boards the parent from the worktree, cold, on the fixed line", :aggregate_failures do
    boarding.board(culprit)
    expect(board_call.first(2)).to eq(["env", "HECKS_NO_RESIDENT=1"])
    expect(board_call).to include("commit=#{parent}", "checkout=#{worktree}", "remote=origin", "branch=main", "--confirm")
    expect(board_call.join(" ")).not_to match(/force|no-verify|OWNER/)
  end

  it "removes the worktree once the boarding pushed" do
    record = boarding.board(culprit)
    expect([calls.last.first.first(3), record["worktree"]]).to eq([["git", "worktree", "remove"], nil])
  end

  it "keeps a queued boarding's worktree and names it" do
    expect(boarding(status: "queued").board(culprit)["worktree"]).to eq(worktree)
  end

  it "removes the worktree and raises when the train refused", :aggregate_failures do
    expect { boarding(accepted: false).board(culprit) }.to raise_error(failure, /did not push/)
    expect(calls.last.first.first(3)).to eq(["git", "worktree", "remove"])
  end

  it "refuses a culprit with no parent" do
    allow(repository).to receive(:first_parent).and_return(nil)
    expect { boarding.board(culprit) }.to raise_error(failure, /no parent/)
  end

  it "refuses a place already taken" do
    FileUtils.mkdir_p(worktree)
    expect { boarding.board(culprit) }.to raise_error(failure, /is taken/)
  end
end
