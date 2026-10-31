require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# A linked worktree lacks the gitignored overlay files of its main checkout, so a command run
# there stores in Memory. The warning says which files are missing, once per process.
RSpec.describe Hecks::Adapters::WorktreeOverlay do
  describe ".missing" do
    it "lists the main checkout's overlay files the worktree lacks" do
      expect(described_class.missing(%w[a.local.world b.local.world], %w[b.local.world]))
        .to eq(%w[a.local.world])
    end

    it "lists nothing when the worktree holds every main file" do
      expect(described_class.missing(%w[a.local.world], %w[a.local.world c.local.world])).to be_empty
    end
  end

  describe ".message" do
    it "names the missing file and the Memory store" do
      expect(described_class.message(%w[lib/hecks/hecks/tickets.local.world]))
        .to include("tickets.local.world", "Memory")
    end

    it "is nil when nothing is missing" do
      expect(described_class.message([])).to be_nil
    end
  end

  describe ".warn_once" do
    it "prints the missing file once per process from a linked worktree" do
      Dir.mktmpdir { |base| expect(warned_twice(base).scan("tickets.local.world").size).to eq(1) }
    end

    def warned_twice(base)
      worktree = build_worktree(base)
      err = StringIO.new
      described_class.instance_variable_set(:@warned, nil)
      2.times { described_class.warn_once(worktree, err: err) }
      err.string
    end

    def build_worktree(base)
      main = File.join(base, "main")
      worktree = File.join(base, "wt")
      FileUtils.mkdir_p([File.join(main, ".git", "worktrees", "wt"), File.join(main, "lib/hecks/hecks"), worktree])
      File.write(File.join(main, "lib/hecks/hecks/tickets.local.world"), "")
      File.write(File.join(worktree, ".git"), "gitdir: #{File.join(main, ".git", "worktrees", "wt")}\n")
      worktree
    end
  end
end
