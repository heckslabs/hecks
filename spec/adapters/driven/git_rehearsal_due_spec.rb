require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"

# The lines `PushRehearsal.Due` adds under its verdict: how far main is behind origin/main and when
# origin/main last moved, the unpushed commits by subject and age, and the last train. A disposable
# bare remote, a clone that pushes to it and one that falls behind; the clock is injected.
RSpec.describe Hecks::Adapters::GitRehearsal::Due, :io do
  IDENT = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@x.test", "GIT_COMMITTER_NAME" => "A",
            "GIT_COMMITTER_EMAIL" => "a@x.test" }.freeze
  let(:scratch) { Dir.mktmpdir("hecks-due") }
  let(:work) { File.join(scratch, "work") }
  let(:now) { Time.at(1_800_000_000) }
  let(:clock) { instance_double(Time.singleton_class, now: now) }

  def git(*args, dir: work, env: {})
    out, err, status = Open3.capture3(IDENT.merge(env), "git", *args, chdir: dir)
    raise "git #{args.join(" ")}: #{err}" unless status.success?

    out.strip
  end

  def commit(subject, hours_ago: 0, dir: work)
    File.write(File.join(dir, "#{subject.hash.abs}.txt"), subject)
    git("add", "-A", dir: dir)
    stamp = "#{now.to_i - (hours_ago * 3600)} +0000"
    git("commit", "-q", "-m", subject, dir: dir, env: { "GIT_AUTHOR_DATE" => stamp, "GIT_COMMITTER_DATE" => stamp })
  end

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("Merge pull request #1 from train/main-a", hours_ago: 2)
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  def lines(dir = work)
    limits = { commits: 15, hours: 6.0, urgent_commits: 40 }
    described_class.new(Hecks::Adapters::Git.new, dir, limits: limits, clock: clock).report.lines.map(&:chomp)
  end

  def tip = git("rev-parse", "origin/main")[0, 9]

  it "names the last train, origin/main's tip, with its subject and age" do
    expect(lines).to include(
      "last train: #{tip} Merge pull request #1 from train/main-a, 2.0 hours ago " \
      "(the tip of origin/main, what the last boarding carried)"
    )
  end

  it "says main is not behind, and when origin/main last moved" do
    expect(lines[1]).to match(%r{\Abehind: 0 commit\(s\) on origin/main that main lacks; origin/main last moved -?[\d.]+ hours})
  end

  it "lists the unpushed commits newest first, by subject and age" do
    commit("older work", hours_ago: 3)
    commit("newer work", hours_ago: 1)

    expect(lines.last(3).map { |line| line.sub(/\h{9} /, "") }).to eq(
      ["unpushed:", "  newer work (1.0 hours old)", "  older work (3.0 hours old)"]
    )
  end

  it "lists at most ten unpushed commits and counts the rest" do
    12.times { |index| commit("work #{index}") }

    expect(lines.last(2)).to match([/\A  \h{9} work 2 \(0\.0 hours old\)\z/, "  and 2 more"])
  end

  it "lists nothing unpushed when main is level" do
    expect(lines).not_to include("unpushed:")
  end

  it "keeps the verdict the first line, as the push-due reader parses it" do
    commit("last quick: red (x) on abc (the current main)")

    expect(lines.first).to start_with("push due: yes; 1 commit(s) ahead of origin/main; oldest unpushed 0.0 hours")
  end

  describe "behind" do
    let(:other) { File.join(scratch, "other") }

    before do
      git("clone", "-q", "origin.git", other, dir: scratch)
      2.times { |index| commit("landed elsewhere #{index}", dir: other) }
      git("push", "-q", "origin", "main", dir: other)
      git("fetch", "-q", "origin")
    end

    it "counts the commits origin/main holds that main lacks" do
      expect(lines[1]).to start_with("behind: 2 commit(s) on origin/main that main lacks; origin/main last moved")
    end

    it "reads the same from a linked worktree, whose fetch state is per worktree" do
      linked = File.join(scratch, "linked")
      git("worktree", "add", "-q", "-b", "side", linked)

      text = Hecks::Adapters::GitRehearsal.new.due(checkout: { value: linked })[:text]

      expect(text.lines[1]).to start_with("behind: 2 commit(s)")
    end
  end
end
