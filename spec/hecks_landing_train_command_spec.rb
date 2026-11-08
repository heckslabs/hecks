require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

# `landing.train!` reaches the adapter through the Hecks bluebook, and records what the train did.
RSpec.describe "the landing.train! command" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-train-command")) }
  let(:repo) { File.join(dir, "main") }

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    File.write(File.join(repo, "README"), "x")
    git("add", ".")
    git("commit", "-m", "first")
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: repo)
    raise out unless status.success?
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def landings
    @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("Landing"))
  end

  it "records that no branch was waiting when the line is empty", :aggregate_failures do
    run = "t-#{SecureRandom.hex(4)}"
    launch("landing.train!", "run=#{run}", "checkout.value=#{repo}", "--confirm", "--wait")
    held = landings.find(run)

    expect(held.status).to eq("convoyed")
    expect(held.report.value).to include("no branch was waiting in the line")
  end
end
