require "spec_helper"
require_relative "support/worktree_scratch"

RSpec.describe Hecks::Adapters::Sweeping::Worktrees, "#lines by landing" do
  include_context "with a scratch worktree repo"

  def lines(held: []) = described_class.new(shell: shell, repo: repo).lines(held: held)

  it "retires a worktree whose tip is on main" do
    tree("done")
    expect(lines.first).to eq("retire  branch=done  checkout=#{File.realpath(root)}/done")
  end

  it "retires one whose commits main holds under other shas" do
    path = tree("squashed")
    commit(path, "x")
    git("cherry-pick", "squashed")
    expect(lines.first).to start_with("retire  branch=squashed")
  end

  it "never retires a worktree with an uncommitted file" do
    File.write(File.join(tree("dirty"), "loose"), "x")
    expect(lines.first).to match(/\Adirty  .*dirty  1 uncommitted file/)
  end

  it "files unlanded commits no item holds, with commits and diffstat", :aggregate_failures do
    commit(tree("ahead"), "y")
    expect(lines.first).to start_with("file  branch=ahead")
    expect(lines.first).to include("commits:", "1 file changed")
  end

  it "leaves unlanded commits to their open item" do
    commit(tree("held"), "z")
    expect(lines(held: ["held"]).first).to start_with("item  branch=held")
  end
end
