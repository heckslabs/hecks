require "spec_helper"

# The control process takes a control line whatever gem environment or local files the caller
# has, and does not go idle; a plain line is judged as before.
RSpec.describe "the control process serving" do
  before do
    require_relative "support/control_process_checkouts"
    extend ControlProcessCheckouts

    require_relative "support/control_process_server"
    extend ControlProcessServer

    build_checkouts
    allow(resident::Paths).to receive(:recall_words).with("control").and_return(%w[work agent])
  end

  let(:control) { true }
  let(:server) { judging_server(control) }

  after { remove_checkouts }

  it "serves a control line whatever gem environment the caller carries" do
    expect(refusal({ "GEM_HOME" => "/elsewhere", "BUNDLE_GEMFILE" => "/x/Gemfile" }, %w[tickets Work.undone])).to be_nil
  end

  it "still refuses a line that is not a control command on a gem environment that differs" do
    expect(refusal({ "GEM_HOME" => "/elsewhere" }, %w[style StyleRun.check_comments!])).to eq("env:GEM_HOME")
  end

  it "serves a control line from a directory that keeps local files of its own" do
    FileUtils.touch(File.join(worktree_dir, "Hecks.local.bluebook"))
    expect(refusal({}, %w[tickets Work.undone], worktree_dir)).to be_nil
  end

  it "never goes idle" do
    quiet_for_a_while
    expect(server.send(:idle?)).to be(false)
  end
end
