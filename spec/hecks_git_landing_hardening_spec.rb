require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"
require "open3"

# Retiring a landed worktree keeps everything that might hold work, and the overlap check sees a
# rename's old path. Every example builds its own throwaway repository; the real one is never read.
RSpec.describe Hecks::Adapters::GitLanding do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-hardening")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:landing) { described_class.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file, text = "x")
    FileUtils.mkdir_p(File.dirname(File.join(where, file)))
    File.write(File.join(where, file), text)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def build_repo(branch = "work/a", *files)
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    git("worktree", "add", "-b", branch, tree)
    files.each { |file| commit(tree, file) }
  end

  def ignore_in_tree(pattern)
    File.write(File.join(tree, ".gitignore"), "#{pattern}\n")
    git("add", ".gitignore", chdir: tree)
    git("commit", "-m", "ignore", chdir: tree)
  end

  # Runs the callables around one private step of every Tidy built while the example runs.
  def hook_tidy(name, before: nil, after: nil)
    allow(described_class::Tidy).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |tidy|
        tidy.singleton_class.define_method(name) do |*held|
          before&.call
          super(*held).tap { after&.call }
        end
      end
    end
  end

  def advance_branch
    empty = git("hash-object", "-t", "tree", File::NULL).strip
    git("commit-tree", empty, "-p", "work/a", "-m", "late").strip.tap { |sha| git("update-ref", "refs/heads/work/a", sha) }
  end

  def ignored_file(name)
    build_repo
    ignore_in_tree(name)
    File.write(File.join(tree, name), "KEY=1")
  end

  def retire(branch = "work/a") = landing.remove(checkout: tree, branch: branch, onto: "main")

  def rename_in_tree
    build_repo
    commit(repo, "lib/old name.rb", "same content\n" * 20)
    git("merge", "main", chdir: tree)
    git("mv", "lib/old name.rb", "lib/new.rb", chdir: tree)
    git("commit", "-m", "rename", chdir: tree)
  end

  def land(branch = "work/a", checkout: repo) = landing.merge(checkout: checkout, branch: branch).dig(:report, :value)

  def branch?(name) = !git("branch", "--list", name).strip.empty?

  it "keeps a worktree holding an ignored file, and names it", :aggregate_failures do
    ignored_file("secret.env")

    expect(land).to include("kept work/a", "secret.env")
    expect(File.read(File.join(tree, "secret.env"))).to eq("KEY=1")
    expect(branch?("work/a")).to be(true)
  end

  it "keeps a worktree holding an untracked file", :aggregate_failures do
    build_repo("work/a", "a.rb")
    File.write(File.join(tree, "notes.txt"), "mine")
    git("commit", "--allow-empty", "-m", "e", chdir: tree)

    expect { land }.to raise_error(failure, /uncommitted work/)
    expect(File.exist?(tree)).to be(true)
  end

  it "keeps the worktree the process stands in", :aggregate_failures do
    build_repo("work/a", "a.rb")
    said = Dir.chdir(tree) { land }

    expect(said).to include("run from the main checkout to retire it")
    expect(File.directory?(tree)).to be(true)
    expect(branch?("work/a")).to be(true)
  end

  it "keeps the worktree a landing runs from", :aggregate_failures do
    build_repo("work/a", "a.rb")

    expect(land(checkout: tree)).to include("run from the main checkout to retire it")
    expect(File.directory?(tree)).to be(true)
  end

  it "leaves the process a directory that exists after a landing" do
    build_repo("work/a", "a.rb")
    land

    expect { Dir.pwd }.not_to raise_error
  end

  it "carries the primary checkout in the answer, which survives the retirement" do
    build_repo("work/a", "a.rb")
    answer = landing.merge(checkout: tree, branch: "work/a")

    expect(answer.dig(:checkout, :value)).to eq(repo)
  end

  it "never deletes stable, edge or main", :aggregate_failures do
    build_repo("stable", "a.rb")

    expect(land("stable")).to include("kept stable", "protected")
    expect(File.directory?(tree)).to be(true)
    expect(branch?("stable")).to be(true)
  end

  it "keeps the branch when a commit lands on it after it was verified", :aggregate_failures do
    build_repo("work/a", "a.rb")
    late = nil
    hook_tidy(:delete_branch, before: -> { late = advance_branch })

    expect(land).to include("kept work/a", "moved after it was verified")
    expect(git("rev-parse", "work/a").strip).to eq(late)
  end

  it "keeps everything when a commit lands in the worktree before the removal", :aggregate_failures do
    build_repo("work/a", "a.rb")
    hook_tidy(:unmerged, after: -> { commit(tree, "late.rb") })

    expect(land).to include("kept work/a", "moved after it was checked")
    expect(File.directory?(tree)).to be(true)
  end

  it "keeps a locked worktree, never forcing", :aggregate_failures do
    build_repo("work/a", "a.rb")
    git("worktree", "lock", tree)

    expect(land).to include("kept work/a", "would not remove")
    expect(File.directory?(tree)).to be(true)
  end

  it "refuses to retire a branch another worktree holds under a different path" do
    build_repo("work/a", "a.rb")
    other = File.join(dir, "other")
    git("worktree", "add", "-b", "work/b", other)

    expect { landing.remove(checkout: other, branch: "work/a", onto: "main") }
      .to raise_error(failure, /not the worktree named/)
  end

  it "removes a clean landed worktree through retire", :aggregate_failures do
    build_repo("work/a", "a.rb")
    git("merge", "work/a")

    expect(retire.dig(:report, :value)).to include("and deleted work/a")
    expect(File.exist?(tree)).to be(false)
    expect(branch?("work/a")).to be(false)
  end

  it "removes a worktree whose commits main holds under rewritten shas", :aggregate_failures do
    build_repo("work/a", "a.rb")
    commit(repo, "b.rb")
    git("cherry-pick", "work/a")

    expect(retire.dig(:report, :value)).to include("and deleted work/a")
    expect([File.exist?(tree), branch?("work/a")]).to eq([false, false])
  end

  it "keeps a worktree with a commit main does not hold even when another is replayed", :aggregate_failures do
    build_repo("work/a", "a.rb", "c.rb")
    git("cherry-pick", "work/a~1")

    expect { retire }.to raise_error(failure, /not on main/)
    expect(branch?("work/a")).to be(true)
  end

  it "refuses to retire a worktree holding an ignored file", :aggregate_failures do
    ignored_file("x.log")
    git("merge", "work/a")

    expect { retire }.to raise_error(failure, /x\.log/)
    expect(File.exist?(File.join(tree, "x.log"))).to be(true)
  end

  describe "the rival check" do
    def holds(*area) = allow(Hecks::Adapters::StartedWork).to receive(:rows).and_return([{ key: "other", area: area }])

    it "sees the old path of a rename", :aggregate_failures do
      rename_in_tree
      holds("lib/old name.rb")

      expect { land }.to raise_error(failure, %r{lib/old name\.rb})
      expect(branch?("work/a")).to be(true)
    end
  end
end
