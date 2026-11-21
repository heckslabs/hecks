require "spec_helper"
require_relative "support/worktree_scratch"

RSpec.describe Hecks::Adapters::Sweeping::Worktrees, "#lines keepers, nesting and counts" do
  include_context "with a scratch worktree repo"

  def lines(keepers: []) = described_class.new(shell: shell, repo: repo, keepers: keepers).lines

  it "keeps a named keeper" do
    tree("train")
    expect(lines(keepers: ["/train"]).first).to start_with("keeper  ")
  end

  it "judges a nested worktree first and keeps the outer", :aggregate_failures do
    outer = tree("outer")
    tree("inner", path: File.join(outer, "inner"))
    expect(lines.first).to start_with("retire  branch=inner")
    expect(lines[1]).to start_with("nested  ").and(include("holds 1 inner"))
  end

  it "counts one per kind" do
    tree("done")
    expect(lines.last).to eq("worktrees  retire=1 dirty=0 item=0 file=0 nested=0 keeper=0 detached=0 temp=0")
  end
end
