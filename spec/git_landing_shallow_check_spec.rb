require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"
require "open3"

# The landing's shallow checks run on a depth-1 clone of a branch that changes a triggered path,
# and refuse the landing by name when the stage is red there. Every example builds its own
# throwaway repository and stands in for the stage with a gate that answers red on a one-commit
# history; the real stage never runs.
RSpec.describe Hecks::Adapters::GitLanding::ShallowCheck do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-shallow")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { FileUtils.remove_entry(dir) }

  def result(out, success)
    Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: success))
  end

  def green = result("{\"status\": \"completed\"}", true)

  # Green only when the history holds more than one commit, as the stage on a full checkout.
  def full_history
    lambda do |where|
      count = git("rev-list", "--count", "HEAD", chdir: where).to_i
      count > 1 ? green : result("shallow: one commit\n", false)
    end
  end

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file)
    FileUtils.mkdir_p(File.dirname(File.join(where, file)))
    File.write(File.join(where, file), "x")
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def build_repo(file)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    git("worktree", "add", "-b", "work/a", tree)
    commit(tree, file)
  end

  def checked(enabled: true, gate: full_history)
    described_class.new(Hecks::Adapters::Git.new, enabled: enabled, gate: gate)
  end

  def prepare(shallow)
    Hecks::Adapters::GitLanding::Finisher.new(Hecks::Adapters::Git.new, tree, branch: "work/a", onto: "main",
                                              gate: ->(_dir) { green }).prepare(shallow)
  end

  it "refuses a bluebook change whose stage passes only on a full history, by name", :aggregate_failures do
    build_repo("orders.bluebook")

    expect { prepare(checked) }.to raise_error(failure, %r{shallow check refused the landing of work/a})
    expect { prepare(checked) }.to raise_error(failure, /shallow: one commit/)
  end

  it "lets a bluebook change through when the stage is green on the shallow clone" do
    build_repo("orders.bluebook")

    expect { prepare(checked(gate: ->(_dir) { green })) }.not_to raise_error
  end

  it "runs no stage and no clone for a docs-only change" do
    build_repo("docs/notes.md")

    expect { prepare(checked(gate: ->(_dir) { raise "the stage ran" })) }.not_to raise_error
  end

  it "runs nothing when switched off, even for a bluebook change" do
    build_repo("orders.bluebook")

    expect { prepare(checked(enabled: false)) }.not_to raise_error
  end

  it "reads the world's switch: on when absent, off only for false", :aggregate_failures do
    expect(described_class.enabled_in?(nil)).to be(true)
    expect(described_class.enabled_in?({ "stale_minutes" => 30 })).to be(true)
    expect(described_class.enabled_in?({ "shallow_checks" => false })).to be(false)
  end
end
