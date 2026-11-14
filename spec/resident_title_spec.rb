require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/stuck"
require "hecks/agents/adapters/sweeping/orphans/rules"

# The names a resident and its lines show in the process table (ADR 0201), and the idle time a
# linked worktree's resident takes. The readers of the process table still find what they look
# for in each title.
RSpec.describe Hecks::Adapters::Driving::Resident::Title do
  let(:root) { "/home/a/hecks/.claude/worktrees/fix-the-thing" }
  let(:script) { "#{root}/exe/hecks" }

  describe "a resident's title" do
    it "names the role and the checkout" do
      expect(described_class.resident(root)).to start_with("hecks resident fix-the-thing ")
    end

    it "is still this checkout's resident to a launcher that would stop a stuck one" do
      found = [Process.uid, described_class.resident(root)]
      expect(Hecks::Adapters::Driving::Resident::Stuck.ours?(found, root)).to be(true)
    end
  end

  describe "a line's title" do
    it "names the launcher, the domain and the command" do
      title = described_class.line(script, %w[tickets Work.undone area.value=lib])
      expect(title).to eq("#{script} tickets Work.undone")
    end

    it "shows no argument, named or bare" do
      title = described_class.line(script, ["Work.note!", "secret", "text.value=private words"])
      expect(title).to eq("#{script} Work.note!")
    end

    it "keeps only the first word of a line that names no command" do
      expect(described_class.line(script, %w[gh pr merge 12])).to eq("#{script} gh")
    end

    it "shows nothing of a line that starts with an argument" do
      expect(described_class.line(script, ["a free text", "Work.undone"])).to eq(script)
    end

    it "holds the worktree's path, which a run's signs of life are read from" do
      expect(described_class.line(script, %w[Work.undone])).to include(root)
    end

    it "is a launcher to the sweep of leftover processes" do
      title = described_class.line(script, %w[tickets Work.undone])
      expect(title).to match(Hecks::Adapters::Sweeping::Orphans::Rules::LAUNCHER)
    end
  end

  describe "naming a process" do
    # The command line `ps` shows for a child that named itself.
    def shown(title)
      reader, writer = IO.pipe
      pid = fork { name_and_look(title, writer) }
      writer.close
      Process.wait(pid)
      reader.read.strip
    end

    def name_and_look(title, writer)
      described_class.apply(title)
      writer.write(IO.popen(["ps", "-o", "command=", "-p", Process.pid.to_s], &:read))
      exit!(0)
    end

    it "changes what the process table shows" do
      expect(shown("hecks resident spec (resident/server.rb /spec)")).to eq("hecks resident spec (resident/server.rb /spec)")
    end
  end

  describe "the idle time" do
    let(:cache) { instance_double(Hecks::Adapters::Driving::Resident::DescribedCache, fetch: nil) }

    def idle_seconds(root)
      server = Hecks::Adapters::Driving::Resident::Server.new(root, "#{root}/exe/hecks")
      server.instance_variable_set(:@cache, cache)
      server.send(:settings)[:idle_seconds]
    end

    it "is the main checkout's where `.git` is a directory" do
      Dir.mktmpdir do |dir|
        Dir.mkdir(File.join(dir, ".git"))
        expect(idle_seconds(dir)).to eq(600.0)
      end
    end

    it "is the shorter one in a linked worktree, where `.git` is a file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".git"), "gitdir: /elsewhere\n")
        expect(idle_seconds(dir)).to eq(120.0)
      end
    end
  end
end
