require "hecks"
require "hecks/hecks/adapters/git"

# The adapter's ref calls run against a real scratch repository and a bare remote, so the git
# arguments are the ones git itself accepts; nothing here touches the network or this checkout.
RSpec.describe Hecks::Adapters::Git do
  subject(:git) { described_class.new }

  around do |example|
    Dir.mktmpdir("git-refs") do |dir|
      @remote = File.join(dir, "remote.git")
      @work = File.join(dir, "work")
      sh(dir, "git", "init", "--bare", "-b", "main", @remote)
      sh(dir, "git", "init", "-b", "main", @work)
      sh(@work, "git", "config", "user.email", "t@example.com")
      sh(@work, "git", "config", "user.name", "T")
      sh(@work, "git", "remote", "add", "origin", @remote)
      example.run
    end
  end

  def sh(dir, *command)
    out, status = Open3.capture2e(*command, chdir: dir)
    raise "#{command.join(" ")}: #{out}" unless status.success?

    out.strip
  end

  def commit!(message)
    File.write(File.join(@work, "f.txt"), message)
    sh(@work, "git", "add", "f.txt")
    sh(@work, "git", "commit", "-m", message)
    sh(@work, "git", "rev-parse", "HEAD")
  end

  def remote(ref) = git.remote_head(ref, chdir: @work)

  def ancestor?(older, newer) = git.ancestor?(older, newer, chdir: @work)

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  describe "#remote_head" do
    it "answers the commit a remote branch names" do
      first = commit!("one")
      sh(@work, "git", "push", "origin", "main")

      expect(remote("refs/heads/main")).to eq(first)
    end

    it "answers nil for a branch the remote lacks" do
      commit!("one")

      expect(remote("refs/heads/stable")).to be_nil
    end
  end

  describe "#ancestor?" do
    it "is true along history, false across it, and true for a commit and itself", :aggregate_failures do
      first = commit!("one")
      second = commit!("two")

      expect(ancestor?(first, second)).to be(true)
      expect(ancestor?(second, first)).to be(false)
      expect(ancestor?(first, first)).to be(true)
    end

    it "refuses a name that is a flag or reaches past a ref", :aggregate_failures do
      expect { ancestor?("--all", "HEAD") }.to raise_error(/not a ref name/)
      expect { ancestor?("HEAD", "a..b") }.to raise_error(/not a ref name/)
    end
  end

  describe "#fast_forward" do
    it "makes a branch on the remote" do
      first = commit!("one")
      git.fast_forward(first, "stable", chdir: @work)

      expect(remote("refs/heads/stable")).to eq(first)
    end

    it "moves a branch forward" do
      git.fast_forward(commit!("one"), "stable", chdir: @work)
      second = commit!("two")
      git.fast_forward(second, "stable", chdir: @work)

      expect(remote("refs/heads/stable")).to eq(second)
    end

    it "is refused, never forced, when the commit does not contain the branch's head" do
      first = commit!("one")
      commit!("two")
      sh(@work, "git", "push", "origin", "HEAD:refs/heads/stable")
      sh(@work, "git", "checkout", "-b", "side", first)

      expect { git.fast_forward(commit!("side"), "stable", chdir: @work) }.to raise_error(failure, /refused/)
    end
  end

  describe "#move_tag" do
    it "creates a tag, then leaves it be when current", :aggregate_failures do
      first = commit!("one")

      expect(git.move_tag("edge", first, chdir: @work)).to eq(:created)
      expect(git.move_tag("edge", first, chdir: @work)).to eq(:current)
    end

    it "moves a tag forward", :aggregate_failures do
      git.move_tag("edge", commit!("one"), chdir: @work)
      second = commit!("two")

      expect(git.move_tag("edge", second, chdir: @work)).to eq(:moved)
      expect(remote("refs/tags/edge")).to eq(second)
    end

    it "refuses to move a tag backward or sideways" do
      first = commit!("one")
      git.move_tag("edge", commit!("two"), chdir: @work)

      expect { git.move_tag("edge", first, chdir: @work) }.to raise_error(failure, /does not contain/)
    end
  end
end
