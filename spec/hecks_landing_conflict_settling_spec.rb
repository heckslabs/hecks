require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "tmpdir"
require "open3"

# Two coders add different aggregates at the same spot of one bluebook. Git's line merge conflicts;
# the landing merges the bluebook by declaration, so both land. Every example builds its own
# throwaway repository and stands in for the gate.
RSpec.describe Hecks::Adapters::GitLanding, "#finish_branch" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-settle")) }
  let(:repo) { File.join(dir, "main") }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:base) { "Hecks.bluebook \"S\" do\n  aggregate \"A\" do\n    attribute :x, String\n  end\nend\n" }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, text)
    File.write(File.join(where, "s.bluebook"), text)
    git("add", ".", chdir: where)
    git("commit", "-m", "edit", chdir: where)
  end

  def adding(name) = base.sub("  end\nend", "  end\n\n  aggregate \"#{name}\" do\n    attribute :y, String\n  end\nend")

  def tree(branch) = File.join(dir, branch)

  def build_repo(*branches)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    %w[name email].each { |key| git("config", "user.#{key}", "t") }
    commit(repo, base)
    branches.each { |branch| git("worktree", "add", "-b", branch, tree(branch)) }
  end

  def green
    Hecks::Adapters::Shell::Result.new("{\"status\": \"completed\"}", "", instance_double(Process::Status, success?: true))
  end

  def finish(branch)
    described_class.new.finish_branch(checkout: tree(branch), branch: branch, onto: "main", gate: ->(_) { green })
  end

  def merger(branch) = described_class::Merger.new(Hecks::Adapters::Git.new, repo, branch: branch, onto: "main")

  def both_edit(mine, theirs)
    build_repo("adds-b", "adds-c")
    commit(tree("adds-b"), mine)
    commit(tree("adds-c"), theirs)
    finish("adds-b")
  end

  it "lands both branches, with both aggregates on main", :aggregate_failures do
    both_edit(adding("B"), adding("C"))
    finish("adds-c")
    expect(git("show", "main:s.bluebook")).to include("aggregate \"B\"", "aggregate \"C\"")
  end

  it "refuses the same declaration changed on both sides, naming it", :aggregate_failures do
    both_edit(base.sub(":x", ":mine"), base.sub(":x", ":theirs"))
    expect { finish("adds-c") }.to raise_error(failure, /s\.bluebook: aggregate A changed on both sides/)
    expect(git("status", "--porcelain", chdir: tree("adds-c"))).to eq("")
  end

  it "settles a conflicting merge commit by declaration" do
    build_repo("adds-b")
    commit(tree("adds-b"), adding("B"))
    commit(repo, adding("C"))
    expect(merger("adds-b").land.dig(:outcome, :value)).to eq("merged")
  end
end
