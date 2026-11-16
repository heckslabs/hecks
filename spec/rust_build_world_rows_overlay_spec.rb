# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require "hecks/hecks/adapters/codebase/heavy_slots"
require "hecks/hecks/adapters/codebase/spec_workers"

# The rows a checkout's readers ask for take the owner's local world over the committed one, a verb
# at a time, read from the main checkout when the checkout is a linked worktree; its persistence
# lines never reach them, and an overlay that cannot be read leaves the committed rows.
RSpec.describe Hecks::RustBuild::WorldRows do
  let(:main) { File.realpath(Dir.mktmpdir("world-rows-main")) }
  let(:worktree) { File.realpath(Dir.mktmpdir("world-rows-worktree")) }
  let(:slots) { Hecks::Adapters::Codebase::HeavySlots }

  before do
    described_class.reset!
    [main, worktree].each { |root| commit_world(root) }
    FileUtils.mkdir_p(File.join(main, ".git/worktrees/wt"))
    File.write(File.join(worktree, ".git"), "gitdir: #{File.join(main, ".git/worktrees/wt")}\n")
  end

  after do
    described_class.reset!
    FileUtils.rm_rf([main, worktree])
  end

  it "gives the overlay's heavy_jobs cap to the main checkout and to its worktree", :aggregate_failures do
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    expect(slots.cap_of(worktree)).to eq(2)
    expect(slots.cap_of(main)).to eq(2)
  end

  it "keeps the committed cap when no overlay is kept" do
    expect(slots.cap_of(worktree)).to eq(1)
  end

  it "keeps the committed cap when the overlay cannot be read" do
    write_overlay(main, malformed)
    expect(quietly { slots.cap_of(worktree) }).to eq(1)
  end

  it "says once on stderr that the overlay could not be read" do
    write_overlay(main, malformed)
    expect { 2.times { slots.cap_of(worktree) && described_class.row(worktree, "spec_workers") } }
      .to output(/\Ahecks: [^\n]*hecks\.local\.world[^\n]*\n\z/).to_stderr
  end

  it "replaces the committed verb whole, as the registry's world merge does" do
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    expect(described_class.row(worktree, "heavy_jobs")).not_to include(:memory_poll_seconds)
  end

  it "keeps the overlay's persistence lines out of every row", :aggregate_failures do
    write_overlay(main, %(persisted_by("SqlitePersistence") { database "/owner/tickets.db" }))
    expect(described_class.row(worktree, "persisted_by")).to eq({})
    expect(described_class.row(worktree, "persisted_by:sqlitepersistence")).to eq({})
  end

  it "gives SpecWorkers the overlay's spec_workers max" do
    write_overlay(main, %(spec_workers "Specs", max: 4))
    expect(Hecks::Adapters::Codebase::SpecWorkers.max_of(worktree)).to eq(4)
  end

  it "reads a worktree's own overlay before the main checkout's" do
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    write_overlay(worktree, %(heavy_jobs "HeavyJobs", cap: 3))
    expect(slots.cap_of(worktree)).to eq(3)
  end

  it "reads only the committed world while overlays are left out" do
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    expect(Hecks::Adapters::FolderOverlay.committed_only { slots.cap_of(worktree) }).to eq(1)
  end

  it "reads an overlay edited between two reads", :aggregate_failures do
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    expect(slots.cap_of(worktree)).to eq(2)
    rewrite_overlay(main, %(heavy_jobs "HeavyJobs", cap: 3))
    expect(slots.cap_of(worktree)).to eq(3)
  end

  it "reads an overlay written after the first read", :aggregate_failures do
    expect(slots.cap_of(worktree)).to eq(1)
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    expect(slots.cap_of(worktree)).to eq(2)
  end

  it "falls back to the committed cap when the overlay is removed", :aggregate_failures do
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    expect(slots.cap_of(worktree)).to eq(2)
    FileUtils.rm(File.join(main, "lib/hecks/hecks/hecks.local.world"))
    expect(slots.cap_of(worktree)).to eq(1)
  end

  it "does not load an unchanged world again" do
    write_overlay(main, %(heavy_jobs "HeavyJobs", cap: 2))
    slots.cap_of(worktree)
    allow(described_class).to receive(:worlds_in).and_call_original
    slots.cap_of(worktree)
    expect(described_class).not_to have_received(:worlds_in)
  end

  # Writes the overlay again with a later modification time, as an edit of the same size does.
  def rewrite_overlay(root, line)
    write_overlay(root, line)
    file = File.join(root, "lib/hecks/hecks/hecks.local.world")
    File.utime(Time.now + 5, Time.now + 5, file)
  end

  def commit_world(root)
    write(root, described_class::WORLD, <<~RUBY)
      Hecks.world "Tickets" do
        heavy_jobs "HeavyJobs", cap: 1, memory_poll_seconds: 10.0
        spec_workers "Specs", max: 6
      end
    RUBY
  end

  def write_overlay(root, line)
    write(root, "lib/hecks/hecks/hecks.local.world", <<~RUBY)
      Hecks.world "Hecks" do
        persisted_by("SqlitePersistence") { database "/owner/agent_run.db" }
      end
      Hecks.world "Tickets" do
        #{line}
      end
    RUBY
  end

  # A heavy_jobs line whose parenthesis never closes, so the world fails to load.
  def malformed = "heavy_jobs \"HeavyJobs\", cap: ("

  def write(root, relative, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
    File.write(File.join(root, relative), text)
  end

  def quietly
    held = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = held
  end
end
