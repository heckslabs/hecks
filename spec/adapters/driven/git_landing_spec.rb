require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/git_checkout"
require "hecks/hecks/adapters/git_copy"

# The Checkout and Landing adapters, against a throwaway repository: a landing fast-forwards or
# merges onto main and reports a conflict, a retirement keeps unmerged or dirty work, and the
# reads say where a checkout stands. The real checkout is never touched.
RSpec.describe "the Checkout and Landing adapters", :io do
  let(:scratch) { File.realpath(Dir.mktmpdir("hecks-landing")) }
  let(:main_tree) { File.join(scratch, "main") }
  let(:feature_tree) { File.join(scratch, "feature") }
  let(:landing) { Hecks::Adapters::GitLanding.new }
  let(:checkout) { Hecks::Adapters::GitCheckout.new }

  def git(*args, dir: main_tree)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, dir:, text: name)
    File.write(File.join(dir, name), text)
    git("add", name, dir: dir)
    git("commit", "-q", "-m", name, dir: dir)
  end

  def land(**held) = landing.merge(checkout: { value: feature_tree }, **held)

  def retire(**held) = landing.remove(checkout: { value: feature_tree }, **held)

  before do
    FileUtils.mkdir_p(main_tree)
    git("init", "-q", "-b", "main")
    git("config", "user.name", "A")
    git("config", "user.email", "a@example.test")
    commit("first", dir: main_tree)
    git("worktree", "add", "-q", "-b", "feat/x", feature_tree)
  end

  after { FileUtils.remove_entry(scratch) }

  it "fast-forwards main onto a branch that is ahead", :aggregate_failures do
    commit("second", dir: feature_tree)

    expect(land).to include(outcome: { value: "fast_forwarded" })
    expect(git("rev-parse", "main")).to eq(git("rev-parse", "feat/x", dir: feature_tree))
  end

  it "merges when main moved, keeping both lines", :aggregate_failures do
    commit("second", dir: feature_tree)
    commit("elsewhere", dir: main_tree)

    expect(land).to include(outcome: { value: "merged" })
    expect(git("log", "--format=%s", "-n", "1", "--merges")).to include("feat/x")
  end

  it "reports a conflict, leaves main as it was and aborts the merge", :aggregate_failures do
    commit("same", dir: feature_tree, text: "theirs")
    commit("same", dir: main_tree, text: "ours")
    before = git("rev-parse", "main")

    expect { land }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /conflicts in same/)
    expect([git("rev-parse", "main"), git("status", "--porcelain")]).to eq([before, ""])
  end

  it "lands onto main when no worktree has it checked out", :aggregate_failures do
    commit("second", dir: feature_tree)
    git("checkout", "-q", "--detach")

    expect(land).to include(outcome: { value: "fast_forwarded" })
    expect(git("rev-parse", "main")).to eq(git("rev-parse", "feat/x", dir: feature_tree))
  end

  it "refuses to land a worktree that holds uncommitted work" do
    commit("second", dir: feature_tree)
    File.write(File.join(feature_tree, "loose"), "x")

    expect { land }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /uncommitted work/)
  end

  it "retires a merged worktree and deletes its branch", :aggregate_failures do
    commit("second", dir: feature_tree)
    land
    retire

    expect(File.directory?(feature_tree)).to be(false)
    expect(git("branch", "--list", "feat/x")).to eq("")
  end

  it "refuses to retire a branch with commits main lacks" do
    commit("second", dir: feature_tree)

    expect { retire }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /1 commit\(s\) not on main/)
  end

  it "refuses to retire a worktree with uncommitted work" do
    File.write(File.join(feature_tree, "loose"), "x")

    expect { retire }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /uncommitted work/)
  end

  it "refuses to retire the primary worktree" do
    expect { landing.remove(checkout: { value: main_tree }, branch: "main") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /its worktree is the main checkout/)
  end

  it "lists the branches whose commits are not on main", :aggregate_failures do
    commit("second", dir: feature_tree)
    text = landing.unlanded(checkout: { value: main_tree })[:text]

    expect(text).to include("feat/x", "1 commit(s) not on main", feature_tree)
  end

  it "says everything is on main once a branch is landed" do
    expect(landing.unlanded(checkout: { value: main_tree })[:text]).to eq("everything is on main\n")
  end

  it "reports the branch, the worktree kind and the changed paths", :aggregate_failures do
    File.write(File.join(feature_tree, "loose"), "x")
    text = checkout.status(checkout: { value: feature_tree })[:text]

    expect(text).to include("branch: feat/x", "worktree: linked", "main: ahead 0, behind 0", "?? loose")
  end

  it "reports what a checkout changed since main, as a stat or as names", :aggregate_failures do
    commit("second", dir: feature_tree)

    expect(checkout.changes(checkout: { value: feature_tree })[:text]).to include("second", "1 file changed")
    expect(checkout.changes(checkout: { value: feature_tree }, names_only: true)[:text]).to eq("second\n")
  end

  it "reports the commits of a range, and refuses what is not one", :aggregate_failures do
    commit("second", dir: feature_tree)

    expect(checkout.history(checkout: { value: feature_tree }, range: "main..HEAD")[:text]).to match(/\A\h+ second\n\z/)
    expect { checkout.history(checkout: { value: feature_tree }, range: "--all") }.to raise_error(Hecks::Runtime::NotFound)
  end

  def log(**held) = checkout.history(checkout: { value: feature_tree }, **held)[:text]

  it "limits the commits to those that add or remove some text", :aggregate_failures do
    commit("second", dir: feature_tree, text: "a needle")
    commit("third", dir: feature_tree)

    expect(log(containing: "needle")).to match(/\A\h+ second\n\z/)
    expect(log(containing: "needle", path: "third")).to eq("\n")
  end

  it "limits the commits to those that touch a path, and refuses a path or text it cannot take", :aggregate_failures do
    commit("third", dir: feature_tree)

    expect(log(path: "third")).to match(/\A\h+ third\n\z/)
    expect { log(path: "../first") }.to raise_error(Hecks::Runtime::NotFound)
    expect { log(containing: "a\nb") }.to raise_error(Hecks::Runtime::NotFound)
  end

  describe "copying a tree as it stood at a ref" do
    def destination = File.join(scratch, "copy")

    def copy(**held) = Hecks::Adapters::GitCopy.new.copy(checkout: { value: feature_tree }, **held)

    it "writes a path, or the whole tree, into a new directory and reports it", :aggregate_failures do
      commit("second", dir: feature_tree, text: "two")

      report = copy(ref: { value: "HEAD" }, path: { value: "second" }, destination: { value: destination })[:report][:value]

      expect(File.read(File.join(destination, "second"))).to eq("two")
      expect(File).not_to exist(File.join(destination, "first"))
      expect(report).to match(/\Acopied 1 files of second at \h+ into #{Regexp.escape(destination)}\z/)
    end

    it "copies the tree as it stood at a parent revision", :aggregate_failures do
      commit("second", dir: feature_tree)
      other = File.join(scratch, "earlier")

      copy(ref: { value: "HEAD^" }, destination: { value: other })

      expect(File).to exist(File.join(other, "first"))
      expect(File).not_to exist(File.join(other, "second"))
    end

    # The copies that are declined: a relative destination, one inside the checkout, one that
    # already holds files, an option for a ref, a path that leaves the repository, and an unknown ref.
    def declined_copies
      File.write(File.join(scratch, "occupied"), "x")
      [{ ref: { value: "HEAD" }, destination: { value: "relative/dir" } },
       { ref: { value: "HEAD" }, destination: { value: File.join(feature_tree, "inside") } },
       { ref: { value: "HEAD" }, destination: { value: File.join(scratch, "occupied") } },
       { ref: { value: "--all" }, destination: { value: destination } },
       { ref: { value: "HEAD" }, path: { value: "../first" }, destination: { value: destination } },
       { ref: { value: "nosuchref" }, destination: { value: destination } }]
    end

    it "declines each copy it must not make and writes nothing", :aggregate_failures do
      declined_copies.each do |held|
        expect { copy(**held) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure), held.inspect
      end
      expect(File).not_to exist(destination)
    end
  end

  describe "showing a file as it stood at a ref" do
    def show(**held) = checkout.show(checkout: { value: feature_tree }, **held)

    it "answers the file exactly as committed, at HEAD and at a parent", :aggregate_failures do
      commit("second", dir: feature_tree, text: "  indented\nline two\n")

      expect(show(ref: "HEAD", path: "second")[:text]).to eq("  indented\nline two\n")
      expect(show(ref: "HEAD^", path: "first")[:text]).to eq("first")
    end

    it "lists the top level when no path is named", :aggregate_failures do
      commit("second", dir: feature_tree)

      expect(show(ref: "HEAD")[:text]).to include("first", "second")
      expect(show(ref: "HEAD^")[:text]).to include("first").and(satisfy { |text| !text.include?("second") })
    end

    it "refuses a missing file, a range, an option and a path that leaves the repository", :aggregate_failures do
      [{ ref: "HEAD", path: "missing" }, { ref: "main..HEAD", path: "first" }, { ref: "--all", path: "first" },
       { ref: "HEAD", path: "../first" }, { ref: "HEAD", path: "/etc/passwd" }, { ref: "HEAD", path: "-first" },
       { ref: "HEAD", path: "./first" }].each do |held|
        expect { show(**held) }.to raise_error(Hecks::Runtime::NotFound), held.inspect
      end
    end

    it "cuts a long file and says so", :aggregate_failures do
      commit("long", dir: feature_tree, text: "x" * (Hecks::Adapters::GitCheckout::SHOWN + 1))
      text = show(ref: "HEAD", path: "long")[:text]

      expect(text).to end_with("\n[cut at 200000 of 200001 characters]\n")
      expect(text.length).to eq(Hecks::Adapters::GitCheckout::SHOWN + "\n[cut at 200000 of 200001 characters]\n".length)
    end
  end
end
