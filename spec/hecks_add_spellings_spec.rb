require "spec_helper"
require "tmpdir"
require "open3"

# The launcher takes both spellings of a command name; each cuts the branch and pulls main first.
RSpec.describe "LinkedTree.add! in both spellings" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-add-spellings")) }
  let(:exe) { File.expand_path("../exe/hecks", __dir__) }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def repo = File.join(dir, "repo")

  before do
    git("init", "--bare", "-b", "main", File.join(dir, "remote.git"), dir)
    git("clone", File.join(dir, "remote.git"), repo, dir)
    git("checkout", "-b", "main", repo) unless git("branch", "--show-current", repo) == "main"
    git("commit", "--allow-empty", "-m", "init", repo)
    git("push", "origin", "main", repo)
    git("clone", File.join(dir, "remote.git"), File.join(dir, "other"), dir)
    git("commit", "--allow-empty", "-m", "theirs", File.join(dir, "other"))
    git("push", "origin", "main", File.join(dir, "other"))
  end

  %w[LinkedTree.add! linked_tree.add!].each do |spelling|
    it "#{spelling} pulls main and cuts the branch", :aggregate_failures do
      branch = "cut-#{spelling.tr(".!", "--")}"
      out, status = Open3.capture2e(exe, spelling, "checkout.value=#{repo}", "branch.value=#{branch}", "--wait")
      expect(status).to be_success, out
      expect(git("branch", "--list", branch, repo)).to include(branch)
      expect(git("rev-parse", "main", repo)).to eq(git("rev-parse", "origin/main", repo))
    end
  end
end
