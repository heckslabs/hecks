# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/heavy_slots"

# The commands the Tickets world declares heavy each take one heavy-job place through one path;
# a command it does not declare, such as a wait on a remote run, takes none and never queues.
RSpec.describe Hecks::Adapters::Codebase::HeavySlots, ".command" do
  let(:root) { File.realpath(Dir.mktmpdir("heavy-commands-root")) }
  let(:cache) { Dir.mktmpdir("heavy-commands-cache") }
  let(:held) { described_class::HELD }

  around do |example|
    saved = ENV.values_at("HECKS_CACHE_DIR", "CI", held)
    holder = Thread.current[:heavy_slot_held]
    Thread.current[:heavy_slot_held] = false
    ENV["HECKS_CACHE_DIR"] = cache
    ENV["CI"] = ENV[held] = nil
    write_world
    Hecks::RustBuild::WorldRows.reset!
    example.run
  ensure
    ENV["HECKS_CACHE_DIR"], ENV["CI"], ENV[held] = saved
    Thread.current[:heavy_slot_held] = holder
    FileUtils.rm_rf([root, cache])
  end

  def write_world
    FileUtils.mkdir_p(File.join(root, "lib/hecks/hecks"))
    File.write(File.join(root, Hecks::RustBuild::WorldRows::WORLD), <<~WORLD)
      Hecks.world "Tickets" do
        heavy_jobs "HeavyJobs", cap: 2
        heavy_commands "HeavyCommands", run_behaviors: "behaviors", run_spec_files: "spec_batch"
      end
    WORLD
  end

  def hold_places(count)
    FileUtils.mkdir_p(described_class.directory)
    Array.new(count) do |index|
      File.new(File.join(described_class.directory, "slot-#{index}.lock"), File::CREAT | File::RDWR, 0o600)
          .tap { |file| file.flock(File::LOCK_EX) }
    end
  end

  it "names the job a declared command takes a place as, and none for another" do
    expect([described_class.job_of(root, "run_behaviors"), described_class.job_of(root, "request")])
      .to eq(["behaviors", nil])
  end

  it "runs a command the world does not declare at once while every place is held" do
    places = hold_places(2)
    expect(described_class.command(root, "request") { :ran }).to eq(:ran)
  ensure
    places&.each(&:close)
  end

  it "makes a third heavy command wait for a place and say so" do
    places = hold_places(2)
    slots = described_class.new(cap: 2, err: (err = StringIO.new), pause: ->(_) { places.shift&.close })
    expect([slots.hold("behaviors") { :ran }.first, err.string]).to match([:ran, /2 of 2 taken/])
  ensure
    places&.each(&:close)
  end

  it "takes one place for a command over many files, not one per file" do
    allow(described_class).to receive(:held).and_call_original
    described_class.command(root, "run_behaviors") { 38.times { :file } }
    expect(described_class).to have_received(:held).with(root, "behaviors").once
  end
end
