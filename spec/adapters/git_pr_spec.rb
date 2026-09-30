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

  describe "the per-day cap" do
    it "is no cap at zero" do
      expect { adapter.assert_under_daily_cap!(opened_today: 50, cap: 0) }.not_to raise_error
    end

    it "takes a day under the cap" do
      expect { adapter.assert_under_daily_cap!(opened_today: 1, cap: 2) }.not_to raise_error
    end

    it "refuses one more pull request than the cap allows" do
      expect { adapter.assert_under_daily_cap!(opened_today: 2, cap: 2) }
        .to raise_error(described_class::Refusal, /2 PR\(s\) already opened since local midnight.*PR_CAP_PER_DAY is 2/m)
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

      gh_answers("", success: false)
      expect(adapter.open_pull_request("qa/x")).to be_nil
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
