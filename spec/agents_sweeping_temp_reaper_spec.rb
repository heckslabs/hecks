require "spec_helper"
require_relative "support/worktree_scratch"

RSpec.describe Hecks::Adapters::Sweeping::Worktrees::TempReaper do
  include_context "with a scratch worktree repo"

  let(:reaper) { described_class.new(shell: shell, repo: repo) }
  let(:path)   { detached("gone") }
  let(:line)   { "temp  #{path}  absorbed, idle, no branch" }

  it "only says what it would remove when asked to read" do
    expect(reaper.apply([line], remove: false)).to eq(["would remove  #{path}"])
  end

  it "removes the worktree and leaves other lines alone", :aggregate_failures do
    expect(reaper.apply([line, "dirty  x"], remove: true)).to eq(["removed  #{path}", "dirty  x"])
    expect(File.exist?(path)).to be(false)
  end

  it "reports a refusal as a line, never forcing" do
    File.write(File.join(path, "untracked"), "x")
    expect(reaper.apply([line], remove: true).first).to start_with("kept  ")
  end
end
