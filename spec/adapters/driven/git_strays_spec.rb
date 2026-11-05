require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/git_checkout"

# What a dirty checkout holds, and moving it out of the way, against a throwaway repository: a stale
# copy of a file main deleted, a linked worktree sitting inside the checkout and a tracked file with
# changes are each named; an untracked path or a clean pushed worktree is moved, never deleted, and
# nothing tracked, unsaved or unpushed is touched. The real checkout is never touched.
RSpec.describe "the strays of a checkout", :io do
  let(:scratch) { File.realpath(Dir.mktmpdir("hecks-strays")) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def main_tree = File.join(scratch, "main")

  def holding = File.join(scratch, "holding")

  def inner = File.join(main_tree, "trees", "inner")

  def git(*args, dir: main_tree)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, dir: main_tree, text: name)
    File.write(File.join(dir, name), text)
    git("add", name, dir: dir)
    git("commit", "-q", "-m", name, dir: dir)
  end

  def strays = Hecks::Adapters::GitCheckout.new.strays(checkout: { value: main_tree })[:text]

  def shelve(path)
    held = { checkout: { value: main_tree }, path: { value: path }, holding: { value: holding } }
    Hecks::Adapters::GitLanding.new.move_aside(**held)[:report][:value]
  end

  def land_from_main
    held = { checkout: { value: main_tree }, branch: { value: "feat/z" }, onto: { value: "main" } }
    Hecks::Adapters::GitLanding.new.merge(**held)
  end

  def publish_to_remote(name)
    remote = File.join(scratch, "origin.git")
    git("init", "-q", "--bare", remote, dir: scratch)
    git("remote", "add", "origin", remote)
    commit(name, dir: inner)
    git("push", "-q", "origin", "feat/y", dir: inner)
  end

  def held_files(pattern) = Dir.glob(File.join(holding, pattern))

  before do
    FileUtils.mkdir_p(main_tree)
    git("init", "-q", "-b", "main")
    git("config", "user.name", "A")
    git("config", "user.email", "a@example.test")
    commit("first")
  end

  after { FileUtils.remove_entry(scratch) }

  it "says a clean checkout has no strays" do
    expect(strays).to eq("no strays\n")
  end

  describe "reading" do
    before do
      commit("gone", text: "the last version")
      git("rm", "-q", "gone")
      git("commit", "-q", "-m", "remove gone")
    end

    it "names the commit that deleted a file and says it equals its last version", :aggregate_failures do
      File.write(File.join(main_tree, "gone"), "the last version")

      expect(strays).to include("gone\tstale\t", "main deleted it in", "remove gone", "identical to its last version")
      expect(strays).to include("recoverable: git show ", "^:gone")
    end

    it "says when the stale copy differs from its last version" do
      File.write(File.join(main_tree, "gone"), "edited since")

      expect(strays).to include("differs from its last version")
    end

    it "calls a file history never held unknown" do
      File.write(File.join(main_tree, "mystery"), "x")

      expect(strays).to include("mystery\tunknown\t")
    end

    it "names a tracked file with uncommitted changes" do
      File.write(File.join(main_tree, "first"), "changed")

      expect(strays).to include("first\tchanged\t", "commit it or leave it to its owner")
    end
  end

  describe "a linked worktree inside the checkout" do
    before { git("worktree", "add", "-q", "--detach", inner) }

    it "is named by its own path, not its parent's", :aggregate_failures do
      expect(strays).to include("trees/inner/\tworktree\t", "detached ")
      expect(strays).not_to include("trees/\t")
    end

    it "is safe to move while clean and with every commit on main" do
      expect(strays).to include("clean", "0 commit(s) not on main", "safe to move")
    end

    it "is kept while it is dirty" do
      File.write(File.join(inner, "loose"), "x")

      expect(strays).to include("dirty", "keep: unsaved or unpushed work")
    end

    it "is kept while a commit exists on no main or remote ref" do
      commit("ahead", dir: inner)

      expect(strays).to include("1 commit(s) not on main, 1 on no main or remote ref", "keep:")
    end
  end

  describe "setting a path aside" do
    it "moves an untracked file into the holding directory", :aggregate_failures do
      File.write(File.join(main_tree, "stray.rb"), "keep me")
      shelve("stray.rb")

      expect(File.read(held_files("*-stray.rb").first)).to eq("keep me")
      expect(git("status", "--porcelain")).to eq("")
    end

    it "says where it went and how to put it back", :aggregate_failures do
      File.write(File.join(main_tree, "stray.rb"), "keep me")
      said = shelve("stray.rb")

      expect(said).to include("moved #{File.join(main_tree, "stray.rb")} to #{held_files("*-stray.rb").first}")
      expect(said).to include("; put it back with: mv #{held_files("*-stray.rb").first} ")
    end

    it "moves an untracked directory whole" do
      FileUtils.mkdir_p(File.join(main_tree, "scraps"))
      File.write(File.join(main_tree, "scraps", "a"), "a")
      shelve("scraps")

      expect(held_files("*-scraps/a").size).to eq(1)
    end

    it "never overwrites an earlier set-aside of the same name" do
      2.times do |time|
        File.write(File.join(main_tree, "twice"), "round #{time}")
        shelve("twice")
      end

      expect(held_files("*-twice*").map { |file| File.read(file) }).to contain_exactly("round 0", "round 1")
    end

    it "refuses a tracked file", :aggregate_failures do
      expect { shelve("first") }.to raise_error(failure, /is tracked/)
      expect(File.exist?(File.join(main_tree, "first"))).to be(true)
    end

    it "refuses a directory with a tracked file inside" do
      FileUtils.mkdir_p(File.join(main_tree, "lib"))
      commit("lib/kept", text: "k")
      File.write(File.join(main_tree, "lib", "extra"), "x")

      expect { shelve("lib") }.to raise_error(failure, /is tracked/)
    end

    it "refuses a path outside the checkout, one inside .git and one that is not there", :aggregate_failures do
      expect { shelve("../elsewhere") }.to raise_error(failure, /is not inside/)
      expect { shelve(".git/config") }.to raise_error(failure, /inside \.git/)
      expect { shelve("nothing") }.to raise_error(failure, /does not exist/)
    end
  end

  describe "setting a linked worktree aside" do
    before { git("worktree", "add", "-q", "-b", "feat/y", inner) }

    it "moves a clean one whose commits are all on main, and git follows it", :aggregate_failures do
      shelve("trees/inner")

      expect(File.directory?(inner)).to be(false)
      expect(git("worktree", "list")).to include(held_files("*-inner").first)
    end

    it "refuses the directory that holds it" do
      expect { shelve("trees") }.to raise_error(failure, /holds the linked worktree/)
    end

    it "refuses a dirty one", :aggregate_failures do
      File.write(File.join(inner, "loose"), "x")

      expect { shelve("trees/inner") }.to raise_error(failure, /uncommitted work/)
      expect(File.directory?(inner)).to be(true)
    end

    it "refuses one with a commit on no main or remote ref", :aggregate_failures do
      commit("ahead", dir: inner)

      expect { shelve("trees/inner") }.to raise_error(failure, /on no main or remote ref; push them first/)
      expect(File.directory?(inner)).to be(true)
    end

    it "moves one whose commit a remote holds" do
      publish_to_remote("ahead")
      shelve("trees/inner")

      expect(File.directory?(inner)).to be(false)
    end
  end

  describe "the landing refusal" do
    it "counts untracked and changed paths and names the query that says what each is" do
      git("checkout", "-q", "-b", "feat/z")
      File.write(File.join(main_tree, "loose"), "x")
      File.write(File.join(main_tree, "first"), "changed")
      asked = /1 untracked, 1 changed\); run `hecks Workspace\.strays checkout\.value=#{main_tree}`/

      expect { land_from_main }.to raise_error(failure, asked)
    end
  end
end
