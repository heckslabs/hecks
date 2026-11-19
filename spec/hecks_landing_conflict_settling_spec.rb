require "spec_helper"
require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/landing/rebase_settling"
require "tmpdir"
require "open3"

# Two coders add different aggregates at the same spot of one bluebook. Git's line merge conflicts;
# the settling merges the bluebook by declaration, so both land. Every example builds its own
# throwaway repository.
RSpec.describe Hecks::Adapters::Landing::RebaseSettling, "#settle" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-settle")) }
  let(:base) { "Hecks.bluebook \"S\" do\n  aggregate \"A\" do\n    attribute :x, String\n  end\nend\n" }
  let(:adapter) { Hecks::Adapters::Git.new }

  after { FileUtils.remove_entry(dir) }

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: dir)
    raise out unless status.success?

    out
  end

  def commit(text, file = "s.bluebook")
    File.write(File.join(dir, file), text)
    git("add", ".")
    git("commit", "-m", "edit")
  end

  def adding(name) = base.sub("  end\nend", "  end\n\n  aggregate \"#{name}\" do\n    attribute :y, String\n  end\nend")

  # Main takes `mine`; the branch `theirs`, made from the same start, is then rebased onto main.
  def rebase_after(mine, theirs, file = "s.bluebook")
    git("init", "-b", "main")
    commit(base, file)
    git("checkout", "-q", "-b", "adds-c")
    commit(theirs, file)
    git("checkout", "-q", "main")
    commit(mine, file)
    git("checkout", "-q", "adds-c")
    described_class.new(adapter, dir, %w[-c user.name=t -c user.email=t@t]).settle(adapter.capture("rebase", "main", chdir: dir))
  end

  it "carries the rebase through, with both aggregates in the bluebook", :aggregate_failures do
    result, why = rebase_after(adding("B"), adding("C"))
    expect([result.ok?, why]).to eq([true, nil])
    expect(File.read(File.join(dir, "s.bluebook"))).to include("aggregate \"B\"", "aggregate \"C\"")
  end

  it "refuses the same declaration changed on both sides, naming it" do
    _, why = rebase_after(base.sub(":x", ":mine"), base.sub(":x", ":theirs"))
    expect(why).to eq("s.bluebook: aggregate A changed on both sides")
  end

  it "refuses a conflict in a file that is not a bluebook" do
    _, why = rebase_after("mine\n", "theirs\n", "notes.txt")
    expect(why).to eq("notes.txt is not a bluebook, so it is not merged by declaration")
  end
end
