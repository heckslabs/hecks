require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"
require "open3"

# One landing is in flight at a time. Every example builds its own throwaway repository.
RSpec.describe Hecks::Adapters::GitLanding do
  let(:dir) { Dir.mktmpdir("hecks-landing-queue") }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:landing) { described_class.new }
  let(:queue) { described_class::InFlight.new(File.join(repo, ".git")) }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    File.write(File.join(repo, "README"), "x")
    git("add", ".")
    git("commit", "-m", "first")
    git("worktree", "add", "-b", "work/a", tree)
    File.write(File.join(tree, "a.rb"), "x")
    git("add", ".", chdir: tree)
    git("commit", "-m", "a", chdir: tree)
  end

  def land = landing.merge(checkout: repo, branch: "work/a")

  it "refuses a landing while another is in flight, naming its branch", :aggregate_failures do
    queue.claim("work/other")

    expect { land }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{work/other \(landing for 0 minutes\)})
    expect(File.exist?(tree)).to be(true)
  end

  it "frees the queue once a landing finishes", :aggregate_failures do
    expect(land.dig(:report, :value)).to include("onto main")
    expect { queue.claim("work/next") }.not_to raise_error
  end

  it "frees the queue when a landing is refused" do
    File.write(File.join(tree, "scratch"), "unsaved")
    land rescue nil # rubocop:disable Style/RescueModifier

    expect { queue.claim("work/next") }.not_to raise_error
  end

  it "supersedes a stale claim and says so", :aggregate_failures do
    described_class::InFlight.new(File.join(repo, ".git"), clock: -> { Time.now - (45 * 60) }).claim("work/crashed")

    said = land.dig(:report, :value)
    expect(said).to include("superseded the abandoned landing of work/crashed (landing for 45 minutes)")
    expect(File.exist?(File.join(repo, ".git", "hecks-landing.claim"))).to be(false)
  end

  it "reads the stale window from the world's setting", :aggregate_failures do
    world = Struct.new(:settings).new({ "landing" => { adapter: "Queue", stale_minutes: 5 } })
    registry = instance_double(Hecks::Runtime::Registry, world: world, bluebook: nil)
    described_class::InFlight.new(File.join(repo, ".git"), clock: -> { Time.now - (10 * 60) }).claim("work/crashed")

    expect(described_class.new(registry: registry).merge(checkout: repo, branch: "work/a").dig(:report, :value))
      .to include("superseded")
  end
end
