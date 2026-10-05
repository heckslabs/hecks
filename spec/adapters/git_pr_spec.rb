require "hecks"
require "tmpdir"
require_relative "../../lib/hecks/quality_control/adapters/git_pr"

# The `GitPr` adapter against a throwaway repository, with `gh` stubbed at `Open3` so the suite
# never reaches GitHub. The `git` calls run for real.
RSpec.describe Hecks::Adapters::GitPr do
  def git(*args)
    system("git", "-c", "user.name=spec", "-c", "user.email=spec@example.com", *args,
           chdir: @repo, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
  end

  def commit_file(name)
    File.write(File.join(@repo, name), "#{name}\n")
    git("add", ".")
    git("commit", "-qm", name)
    Dir.chdir(@repo) { `git rev-parse HEAD`.strip }
  end

  def gh_answers(stdout, success: true, stderr: "")
    allow(Open3).to receive(:capture3).with("gh", any_args)
                                      .and_return([stdout, stderr, instance_double(Process::Status, success?: success)])
  end

  def gh_ok(stdout = "") = [stdout, "", instance_double(Process::Status, success?: true)]

  subject(:adapter) { described_class.new(repo_dir: @repo) }

  before do
    @repo = Dir.mktmpdir("git_pr_spec")
    git("init", "-q", "-b", "main")
    # A commit can start detached background maintenance, which creates and removes
    # `.git/objects/maintenance.lock` while `after` deletes the repository.
    git("config", "maintenance.auto", "false")
    git("config", "gc.auto", "0")
    @first = commit_file("one")
  end

  after { FileUtils.remove_entry(@repo) }

  describe "the checkout" do
    it "names the branch and the head commit" do
      git("checkout", "-qb", "qa/x")

      expect(adapter.branch).to eq("qa/x")
      expect(adapter.head).to eq(@first)
    end

    it "refuses a directory that is not a checkout" do
      Dir.mktmpdir("git_pr_not_a_repo") do |dir|
        expect { described_class.new(repo_dir: dir).branch }.to raise_error(described_class::Refusal, /not a git checkout/)
      end
    end

    it "refuses a dirty tree, and names what is dirty" do
      File.write(File.join(@repo, "loose"), "x")

      expect { adapter.assert_clean_tree! }.to raise_error(described_class::Refusal, /dirty.*loose/m)
    end

    it "takes a clean tree" do
      expect { adapter.assert_clean_tree! }.not_to raise_error
    end
  end

  describe "the fix commit" do
    it "takes a commit the branch carries" do
      commit_file("two")

      expect { adapter.assert_ancestor!(commit: @first, owner: "BUG#1") }.not_to raise_error
    end

    it "refuses a commit the branch does not carry, naming what it belongs to" do
      expect { adapter.assert_ancestor!(commit: "deadbeef1", owner: "BUG#1") }
        .to raise_error(described_class::Refusal, /BUG#1's own fix commit deadbee is not an ancestor of HEAD/)
    end
  end

  describe "the fix commit on the pushed branch" do
    before do
      @remote = Dir.mktmpdir("git_pr_remote")
      system("git", "init", "-q", "--bare", "-b", "main", @remote, out: File::NULL, err: File::NULL)
      git("remote", "add", "origin", @remote)
      git("checkout", "-qb", "qa/x")
    end

    after { FileUtils.remove_entry(@remote) }

    it "refuses a branch that is not pushed, even when HEAD carries the commit" do
      expect { adapter.assert_pushed!(branch: "qa/x", commit: @first, owner: "BUG#1") }
        .to raise_error(described_class::Refusal, %r{qa/x is not pushed to origin})
    end

    it "refuses a commit made after the last push" do
      git("push", "-q", "origin", "qa/x")
      fix = commit_file("fix")

      expect { adapter.assert_pushed!(branch: "qa/x", commit: fix, owner: "BUG#1") }
        .to raise_error(described_class::Refusal, %r{not an ancestor of the pushed origin/qa/x})
    end

    it "takes a commit the pushed tip carries" do
      fix = commit_file("fix")
      git("push", "-q", "origin", "qa/x")

      expect { adapter.assert_pushed!(branch: "qa/x", commit: fix, owner: "BUG#1") }.not_to raise_error
    end

    it "refuses a PR head that does not carry the commit" do
      fix = commit_file("fix")

      expect { adapter.assert_pr_head!(head: @first, commit: fix, owner: "BUG#1") }
        .to raise_error(described_class::Refusal, /not an ancestor of the PR head/)
      expect { adapter.assert_pr_head!(head: fix, commit: @first, owner: "BUG#1") }.not_to raise_error
    end
  end

  describe "a commit that is not a sha" do
    it "is refused before it reaches git, so it cannot pass as an option" do
      expect(Open3).not_to receive(:capture3)

      expect { adapter.assert_ancestor!(commit: "--all", owner: "BUG#1") }
        .to raise_error(described_class::Refusal, /does not look like a sha/)
    end
  end

  describe "pull requests" do
    it "finds the open one for a branch" do
      gh_answers(JSON.generate(number: 7, state: "OPEN", url: "u", headRefName: "qa/x", headRefOid: @first, title: "t"))

      expect(adapter.open_pull_request("qa/x")).to include(number: 7, headRefOid: @first)
    end

    it "finds none when the branch's PR is closed, or gh knows none" do
      gh_answers(JSON.generate(number: 7, state: "MERGED"))
      expect(adapter.open_pull_request("qa/x")).to be_nil

      gh_answers("", success: false, stderr: "no pull requests found for branch \"qa/x\"")
      expect(adapter.open_pull_request("qa/x")).to be_nil
    end

    it "does not read a gh network failure as there being no PR" do
      gh_answers("", success: false, stderr: "error connecting to api.github.com")

      expect { adapter.open_pull_request("qa/x") }
        .to raise_error(described_class::CommandFailed, %r{gh pr view qa/x failed — error connecting})
    end

    it "refuses clearly when gh or git is not installed, not with Errno::ENOENT" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect { adapter.open_pull_request("qa/x") }.to raise_error(described_class::Refusal, /gh is not installed/)
      expect { adapter.branch }.to raise_error(described_class::Refusal, /git is not installed/)
    end

    it "opens one, as a draft when asked" do
      allow(Open3).to receive(:capture3)
        .with("gh", "pr", "create", "--head", "qa/x", "--title", "t", "--body", "b", "--draft", chdir: @repo)
        .and_return(gh_ok("https://example.com/pull/7"))

      expect(adapter.create_pull_request(branch: "qa/x", title: "t", body: "b", draft: true))
        .to eq("https://example.com/pull/7")
    end

    it "says what gh said when it refuses to open one" do
      gh_answers("", success: false, stderr: "no permission")

      expect { adapter.create_pull_request(branch: "qa/x", title: "t", body: "b") }
        .to raise_error(described_class::CommandFailed, /gh pr create failed — no permission/)
    end

    it "queues the merge for when checks pass" do
      allow(Open3).to receive(:capture3)
        .with("gh", "pr", "merge", "7", "--auto", "--squash", chdir: @repo).and_return(gh_ok)

      expect { adapter.merge_when_green(7) }.not_to raise_error
    end

    it "reads a tracked PR's state and its checks, and reports a failure by name" do
      gh_answers(JSON.generate(state: "OPEN", headRefOid: @first, url: "u"))
      expect(adapter.pull_request(7)).to eq(state: "OPEN", headRefOid: @first, url: "u")

      gh_answers(JSON.generate([{ name: "rspec", bucket: "pass" }]))
      expect(adapter.checks(7)).to eq([{ name: "rspec", bucket: "pass" }])

      gh_answers("", success: false, stderr: "rate limited")
      expect { adapter.checks(7) }.to raise_error(described_class::CommandFailed, /gh pr checks failed — rate limited/)
    end
  end
end
