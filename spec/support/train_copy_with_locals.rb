# frozen_string_literal: true

require "support/train_scratch_repo"

# A main checkout with a local file, a skipped one, and a train copy beside it.
RSpec.shared_context "with a train copy" do
  include TrainScratchRepo

  let(:copy) { File.join(Dir.mktmpdir("beat-locals"), "hecks-train") }

  before do
    git("init", "-q", "-b", "main")
    commit("first")
    git("worktree", "add", "-q", "--detach", copy, "HEAD")
    File.write(File.join(repo, "agents.local.world"), "primary")
    FileUtils.mkdir_p(File.join(repo, "vendor"))
    File.write(File.join(repo, "vendor", "x.local.world"), "skipped")
  end
end
