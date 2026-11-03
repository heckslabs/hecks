require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"
require "open3"

# A landing refuses a branch whose generated output is stale. Every example builds a throwaway
# repository with `main` and a branch, and stands in for the projections with a recording runner;
# no real projection is run.
RSpec.describe Hecks::Adapters::GitLanding::Generated, "#refuse_stale!" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-generated")) }
  let(:repo) { File.join(dir, "repo") }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:calls) { [] }

  after { FileUtils.remove_entry(dir) }

  def result(text, passed)
    Hecks::Adapters::Shell::Result.new(text, "", instance_double(Process::Status, success?: passed))
  end

  def runner(text, passed)
    lambda do |args, _dir|
      calls << args
      result(text, passed)
    end
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: repo)
    raise out unless status.success?

    out
  end

  def commit(file, text = "x")
    FileUtils.mkdir_p(File.dirname(File.join(repo, file)))
    File.write(File.join(repo, file), text)
    git("add", ".")
    git("commit", "-m", file)
  end

  def branch_with(file)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit("README")
    git("checkout", "-b", "feature")
    commit(file)
  end

  def generated(answer)
    described_class.new(Hecks::Adapters::Git.new, repo, branch: "feature", onto: "main", runner: answer)
  end

  it "refuses a stale README index by naming the file and the command that rewrites it" do
    branch_with("lib/hecks/language/x.bluebook")
    expect { generated(runner("drift in docs/README_INDEX.md\n", false)).refuse_stale! }
      .to raise_error(failure, %r{generated output is stale: docs/README_INDEX\.md: run exe/hecks})
  end

  it "lands a branch whose regenerated output matches its projections" do
    branch_with("lib/hecks/language/x.bluebook")
    expect { generated(runner("", true)).refuse_stale! }.not_to raise_error
  end

  it "runs no projection for a docs-only change" do
    branch_with("docs/notes.md")
    generated(runner("", true)).refuse_stale!
    expect(calls).to be_empty
  end
end
