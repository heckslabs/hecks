require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/session_inbox"

# The inbox a working session's hooks read, in a temporary directory: an answer left there is
# handed to the model once, by a hook that exits 2, and a hook that finds nothing exits 0 so a
# session that ends its turn with an empty inbox is never held open.
RSpec.describe Hecks::Adapters::SessionInbox do
  let(:scratch) { File.realpath(Dir.mktmpdir("session-inbox")) }
  let(:inbox) { described_class.new(directory: scratch) }

  after { FileUtils.rm_rf(scratch) }

  # Runs the run's hook command as Claude Code does, through a shell.
  def run_hook(run = "fix-it") = Open3.capture3("/bin/sh", "-c", inbox.hook(run))

  it "hands a waiting answer to the model on stderr and exits 2", :aggregate_failures do
    inbox.leave("fix-it", "use the staging branch")
    _out, err, status = run_hook

    expect(status.exitstatus).to eq(2)
    expect(err).to eq("Answer from the pipeline:\nuse the staging branch")
  end

  it "takes the answer, so a second hook finds nothing and exits 0", :aggregate_failures do
    inbox.leave("fix-it", "go on")
    run_hook
    _out, err, status = run_hook

    expect(status.exitstatus).to eq(0)
    expect(err).to be_empty
  end

  it "exits 0 with nothing waiting" do
    expect(run_hook.last.exitstatus).to eq(0)
  end

  it "keeps one run's answer from another run's hook", :aggregate_failures do
    inbox.leave("fix-it", "go on")

    expect(run_hook("other-run").last.exitstatus).to eq(0)
    expect(File.read(inbox.path("fix-it"))).to eq("go on")
  end
end
