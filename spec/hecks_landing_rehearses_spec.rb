require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

# A successful land asks for the quick push rehearsal under the primary checkout it carries, so the
# rehearsal runs even though the retired worktree is gone. The stages are stubbed; the repository
# is a throwaway one.
RSpec.describe "a landing followed by its rehearsal" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-rehearses")) }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:stages) { instance_double(Hecks::Adapters::GitRehearsal::Stages, run: []) }

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    commit(repo, "README")
    git("worktree", "add", "-b", "work/a", tree)
    commit(tree, "a.rb")
    allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_return(stages)
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def commit(where, file)
    File.write(File.join(where, file), "x")
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def last_rehearsal = File.join(repo, ".git", Hecks::Adapters::GitRehearsal::Record::QUICK)

  it "rehearses main quickly after the land, from the worktree the land retired", :aggregate_failures do
    launch("landing.land!", "run=l-#{SecureRandom.hex(4)}", "checkout.value=#{tree}", "branch.value=work/a",
           "--confirm", "--wait")
    landed = git("rev-parse", "main").strip

    expect(File.exist?(tree)).to be(true)
    expect(File.read(last_rehearsal)).to start_with("#{landed} green")
  end

  it "rehearses main quickly when the land retired its worktree", :aggregate_failures do
    launch("landing.land!", "run=l-#{SecureRandom.hex(4)}", "checkout.value=#{repo}", "branch.value=work/a",
           "--confirm", "--wait")
    landed = git("rev-parse", "main").strip

    expect(File.exist?(tree)).to be(false)
    expect(File.read(last_rehearsal)).to start_with("#{landed} green")
  end
end
