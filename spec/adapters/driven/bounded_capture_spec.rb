require "spec_helper"
require "rbconfig"
require "tmpdir"
require "hecks/hecks/adapters/bounded_capture"

# A program run under a wall-clock bound, read from real children: one that ends, one that writes
# where it is (as spec_progress.rb does for an example) and then sleeps past the bound.
RSpec.describe Hecks::Adapters::BoundedCapture do
  let(:dir) { Dir.mktmpdir("bounded-capture") }
  let(:capture) { described_class.new(seconds: 1, setting: "spec_bounds.file_seconds") }

  after { FileUtils.rm_rf(dir) }

  # A fake spec process: it says which file and example it is in, starts a grandchild that
  # sleeps too, writes the grandchild's pid to a file, and sleeps past the bound.
  def hanging_spec
    script = <<~RUBY
      File.write(ENV.fetch("#{described_class::PROGRESS}"), "./spec/fake_spec.rb\\tthe fake waits")
      File.write("pid", spawn(RbConfig.ruby, "-e", "sleep 30").to_s)
      puts "started"
      sleep 30
    RUBY
    [RbConfig.ruby, "-e", script]
  end

  # A run of its own, not one that shares the progress file of the run this spec is in.
  def bounded(argv) = capture.call(argv, env: { described_class::PROGRESS => nil }, chdir: dir)

  def stopped = bounded(hanging_spec)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  it "answers what a program that ends printed, and its status", :aggregate_failures do
    result = bounded([RbConfig.ruby, "-e", "print 1; warn 2; exit 3"])
    expect([result.out, result.err, result.status, result.stopped]).to eq(["1", "2\n", 3, false])
  end

  it "ends a program that runs past the bound, naming the file and example it was in", :aggregate_failures do
    result = stopped
    expect([result.stopped, result.status.zero?]).to eq([true, false])
    expect(result.out).to include("started")
    expect(result.err).to include("ran past the 1-second bound (spec_bounds.file_seconds)",
                                  "in ./spec/fake_spec.rb, example \"the fake waits\"")
  end

  it "ends the whole process tree, not only the program it started" do
    stopped
    expect(alive?(Integer(File.read(File.join(dir, "pid"))))).to be(false)
  end

  it "says when the program stopped before any example started" do
    result = bounded([RbConfig.ruby, "-e", "sleep 30"])
    expect(result.err).to include("before any example started")
  end

  it "reads a bound from the Tickets world, and its own default when the world names none", :aggregate_failures do
    expect(described_class.seconds(Hecks::RustBuild::ROOT, :file_seconds)).to eq(600)
    expect(described_class.seconds(dir, :check_seconds)).to eq(described_class::DEFAULTS[:check_seconds])
  end
end
