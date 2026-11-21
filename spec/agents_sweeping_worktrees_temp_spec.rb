require "spec_helper"
require_relative "support/worktree_scratch"

RSpec.describe Hecks::Adapters::Sweeping::Worktrees, "#lines for a detached worktree" do
  include_context "with a scratch worktree repo"

  it "is temp when under a temp root, idle a day and absorbed" do
    detached("old")
    expect(judged(temp: temp)).to start_with("temp  ")
  end

  it "compares through the real path, so a symlinked temp root still matches" do
    link = File.join(root, "link").tap { |path| File.symlink(File.realpath(root), path) }
    detached("viaroot")
    expect(judged(temp: temp(roots: [link]))).to start_with("temp  ")
  end

  it "stays detached when young or outside a temp root", :aggregate_failures do
    detached("young")
    expect(judged(temp: temp(clock: -> { Time.now }))).to start_with("detached  ")
    expect(judged(temp: temp(roots: ["/nonexistent"]))).to start_with("detached  ")
  end

  it "is dirty, not temp, with an uncommitted file" do
    File.write(File.join(detached("loose"), "x"), "x")
    expect(judged(temp: temp)).to start_with("dirty  ")
  end

  it "stays detached when it holds commits main lacks" do
    commit(detached("ahead"), "w")
    expect(judged(temp: temp)).to start_with("detached  ").and(include("holds commits main lacks"))
  end
end
