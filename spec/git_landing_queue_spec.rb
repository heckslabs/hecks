require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "tmpdir"
require "open3"

# Landings go through the line one at a time. Every example builds its own throwaway repository.
RSpec.describe Hecks::Adapters::GitLanding do
  let(:dir) { Dir.mktmpdir("hecks-landing-queue") }
  let(:repo) { File.join(dir, "main") }
  let(:tree) { File.join(dir, "tree") }
  let(:tune) { { locks: [], say: ->(_text) {}, heartbeat: 0.05 } }
  let(:line) { described_class::Line.new(File.join(repo, ".git")) }

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

  def land = described_class.new(**tune).merge(checkout: repo, branch: "work/a")

  def registry
    world = Struct.new(:settings).new({ "landing" => { adapter: "Queue", stale_minutes: 5, wait_minutes: 0.02 } })
    instance_double(Hecks::Runtime::Registry, world: world, bluebook: nil)
  end

  def held_front
    line.join("work/other", ready: true).tap { |held| line.promote(held) }
  end

  def impatient(**more) = described_class.new(**tune, wait_minutes: 0.02, **more).merge(checkout: repo, branch: "work/a")

  it "gives up after the wait window, naming the holder", :aggregate_failures do
    held = held_front

    expect { impatient }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{work/a is not landed: .* work/other})
    expect(File.exist?(tree)).to be(true)
    line.leave(held)
  end

  it "frees the line once a landing finishes", :aggregate_failures do
    expect(land.dig(:report, :value)).to include("onto main")
    expect(line.standing(line.join("work/next", ready: true)).ahead).to be_empty
  end

  it "frees the line when a landing is refused" do
    File.write(File.join(tree, "scratch"), "unsaved")
    land rescue nil # rubocop:disable Style/RescueModifier

    expect(line.standing(line.join("work/next", ready: true)).ahead).to be_empty
  end

  it "supersedes an abandoned ticket and says so", :aggregate_failures do
    late = -> { Time.now - (45 * 60) }
    described_class::Line.new(File.join(repo, ".git"), clock: late).join("work/crashed", ready: true).close

    said = land.dig(:report, :value)
    expect(said).to include("superseded the abandoned landing of work/crashed (landing for 45 minutes)")
    expect(File.exist?(File.join(repo, ".git", "hecks-landing.claim"))).to be(false)
  end

  it "reads the limits from the world's setting" do
    held = held_front

    expect { described_class.new(registry: registry, **tune).merge(checkout: repo, branch: "work/a") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /waited/)
    line.leave(held)
  end
end
