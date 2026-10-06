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
    raise "#{command.join(' ')}: #{out}" unless status.success?

    out.strip
  end

  def commit!(message)
    File.write(File.join(@work, "f.txt"), message)
    sh(@work, "git", "add", "f.txt")
    sh(@work, "git", "commit", "-m", message)
    sh(@work, "git", "rev-parse", "HEAD")
  end

  describe "#remote_head" do
    it "answers the commit a remote branch names, and nil for one it lacks" do
      first = commit!("one")
      sh(@work, "git", "push", "origin", "main")

      expect(git.remote_head("refs/heads/main", chdir: @work)).to eq(first)
      expect(git.remote_head("refs/heads/stable", chdir: @work)).to be_nil
    end
  end

  describe "#ancestor?" do
    it "is true along history, false across it, and true for a commit and itself" do
      first = commit!("one")
      second = commit!("two")

      expect(git.ancestor?(first, second, chdir: @work)).to be(true)
      expect(git.ancestor?(second, first, chdir: @work)).to be(false)
      expect(git.ancestor?(first, first, chdir: @work)).to be(true)
    end

    it "refuses a name that is a flag or reaches past a ref" do
      expect { git.ancestor?("--all", "HEAD", chdir: @work) }.to raise_error(/not a ref name/)
      expect { git.ancestor?("HEAD", "a..b", chdir: @work) }.to raise_error(/not a ref name/)
    end
  end

  describe "#fast_forward" do
    it "makes a branch on the remote, then moves it forward" do
      first = commit!("one")
      git.fast_forward(first, "stable", chdir: @work)
      expect(git.remote_head("refs/heads/stable", chdir: @work)).to eq(first)

      second = commit!("two")
      git.fast_forward(second, "stable", chdir: @work)
      expect(git.remote_head("refs/heads/stable", chdir: @work)).to eq(second)
    end

    it "is refused, never forced, when the commit does not contain the branch's head" do
      first = commit!("one")
      commit!("two")
      sh(@work, "git", "push", "origin", "HEAD:refs/heads/stable")
      sh(@work, "git", "checkout", "-b", "side", first)
      side = commit!("side")

      expect do
        git.fast_forward(side, "stable", chdir: @work)
      end.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /refused/)
    end
  end

  describe "#move_tag" do
    it "creates a tag, leaves it be when current, and moves it forward" do
      first = commit!("one")
      expect(git.move_tag("edge", first, chdir: @work)).to eq(:created)
      expect(git.move_tag("edge", first, chdir: @work)).to eq(:current)

      second = commit!("two")
      expect(git.move_tag("edge", second, chdir: @work)).to eq(:moved)
      expect(git.remote_head("refs/tags/edge", chdir: @work)).to eq(second)
    end

    it "refuses to move a tag backward or sideways" do
      first = commit!("one")
      second = commit!("two")
      git.move_tag("edge", second, chdir: @work)

      expect do
        git.move_tag("edge", first, chdir: @work)
      end.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /does not contain/)
    end
  end
end
