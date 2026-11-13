# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/codebase/heavy_slots"
require "hecks/hecks/adapters/codebase/gate"
require "hecks/hecks/adapters/codebase/batch_runs"

# At most `cap` heavy jobs at once on the machine: a job that finds every slot taken waits, says
# so, and runs when one is let go; a slot whose holder died is free again; a job its parent holds a
# slot for never waits.
RSpec.describe Hecks::Adapters::Codebase::HeavySlots do
  let(:dir) { Dir.mktmpdir("heavy-slots") }
  let(:err) { StringIO.new }

  after { FileUtils.rm_rf(dir) }

  it "runs the job at once while a slot is free and names no wait" do
    expect(slots.hold("gate") { :ran }).to eq([:ran, ""])
  end

  it "runs a third batch only after one of two holders lets go", :aggregate_failures do
    result, note = third_batch

    expect(result).to be(true)
    expect(note).to include("waited")
    expect(err.string).to include("waiting for a heavy-job slot, 2 of 2 taken")
  end

  it "takes the slot of a holder that died at once" do
    pid = dead_holder
    expect(slots(cap: 1).hold("compile") { :ran }).to eq([:ran, ""]), "slot of pid #{pid} stayed held"
  end

  it "does not count the wait against the job's own clock", :aggregate_failures do
    note, started = timed_wait

    expect(note).to eq("waited 2 s for a heavy-job slot (1 of 1 taken)")
    expect(started).to be > 2
  end

  it "never waits when its parent holds a slot, in CI or when switched off", :aggregate_failures do
    2.times { |index| taken(index) }

    [{ described_class::HELD => "1" }, { "CI" => "true" }, { "HECKS_NO_HEAVY_SLOT" => "1" }].each do |base|
      expect(slots(base: base).hold("gate") { :ran }).to eq([:ran, ""])
    end
  end

  it "marks the children it starts as held, so a nested job does not wait for its own slot" do
    outer = slots(cap: 1).hold("gate") { slots(cap: 1, base: ENV).hold("spec_batch") { :nested } }
    expect(outer.first).to eq([:nested, ""])
  end

  it "reads its cap from the Tickets world's heavy_jobs line" do
    expect(described_class.cap_of(File.expand_path("..", __dir__))).to eq(3)
  end

  it "names the wait at the top of the job's report" do
    allow(described_class).to receive(:new).and_return(instance_double(described_class, hold: ["2 examples", "waited 4 s"]))
    expect(described_class.admitted(dir, "gate") { "unused" }).to eq("waited 4 s\n2 examples")
  end

  it "is taken by a gate run and by a run of several spec files", :aggregate_failures do
    run_both_callers

    expect(described_class).to have_received(:admitted).with(dir, "gate")
    expect(described_class).to have_received(:admitted).with(dir, "spec_batch")
  end

  # Runs a quick gate and a run of one spec file with the place taking stubbed out.
  def run_both_callers
    allow(described_class).to receive(:admitted).and_return("ran")
    tree = instance_double(Hecks::Adapters::Codebase::Tree, root: dir)
    Hecks::Adapters::Codebase::Gate.call("gate", { stage: "quick" }, tree)
    Hecks::Adapters::Codebase::BatchRuns.call("run_spec_files", { files: "spec/a_spec.rb" }, tree)
  end

  def slots(cap: 2, base: {}, **options)
    described_class.new(cap: cap, dir: dir, base: base, err: err, **options)
  end

  # A clock that moves a second each time it is asked.
  def ticking = (0..20).each.method(:next).to_proc

  # Takes slot +index+ as a running job would, naming its class and this process.
  def taken(index, job = "spec_batch")
    FileUtils.mkdir_p(dir)
    File.new(File.join(dir, "slot-#{index}.lock"), File::CREAT | File::RDWR).tap do |file|
      file.flock(File::LOCK_EX)
      file.write("#{job} #{Process.pid}")
      file.flush
    end
  end

  # Two batches hold both slots and the first lets go on the sixth pause. Answers whether the
  # third ran after that, and its note.
  def third_batch
    first = taken(0)
    taken(1)
    pauses = 0
    pause = ->(_seconds) { first.close if (pauses += 1) == 6 }
    slots(clock: ticking, pause: pause).hold("spec_batch") { first.closed? }
  end

  # One holder lets go on the first pause. Answers the note and the clock when the job started.
  def timed_wait
    first = taken(0)
    clock = ticking
    started = nil
    _, note = slots(cap: 1, clock: clock, pause: ->(_seconds) { first.close }).hold("gate") { started = clock.call }
    [note, started]
  end

  # Starts a process that takes slot 0 and is killed while holding it.
  def dead_holder
    FileUtils.mkdir_p(dir)
    script = "f = File.new(ARGV[0], File::CREAT | File::RDWR); f.flock(File::LOCK_EX); puts :held; $stdout.flush; sleep 30"
    stdin, out, thread = Open3.popen2(RbConfig.ruby, "-e", script, File.join(dir, "slot-0.lock"))
    out.gets
    Process.kill(:KILL, thread.pid)
    thread.join
    [stdin, out].each(&:close)
    thread.pid
  end
end
