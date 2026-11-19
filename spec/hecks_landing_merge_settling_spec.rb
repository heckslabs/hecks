require "spec_helper"
require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/landing/conflict_settling"
require "tmpdir"
require "open3"

# A merge that conflicts only in a bluebook is settled by declaration and staged, ready to commit.
RSpec.describe Hecks::Adapters::Landing::ConflictSettling, "#refusal" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-merge-settle")) }
  let(:base) { "Hecks.bluebook \"S\" do\n  aggregate \"A\" do\n    attribute :x, String\n  end\nend\n" }

  after { FileUtils.remove_entry(dir) }

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: dir)
    raise out unless status.success? || args.first == "merge"

    out
  end

  def commit(text)
    File.write(File.join(dir, "s.bluebook"), text)
    git("add", ".")
    git("commit", "-m", "edit")
  end

  def adding(name) = base.sub("  end\nend", "  end\n\n  aggregate \"#{name}\" do\n    attribute :y, String\n  end\nend")

  def conflicted_merge
    git("init", "-b", "main")
    commit(base)
    git("checkout", "-q", "-b", "adds-b")
    commit(adding("B"))
    git("checkout", "-q", "main")
    commit(adding("C"))
    git("merge", "--no-ff", "adds-b")
  end

  it "settles a conflicted merge by declaration and stages it", :aggregate_failures do
    conflicted_merge
    expect(described_class.new(Hecks::Adapters::Git.new, dir).refusal).to be_nil
    expect(git("diff", "--cached", "--name-only", "--diff-filter=U")).to eq("")
  end
end
