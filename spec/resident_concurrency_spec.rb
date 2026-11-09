require "spec_helper"
require "etc"
require "json"
require "open3"
require_relative "support/resident_launch"

# A resident under concurrent launchers: many lines arrive at once, as when several sessions run
# their commands together, on a machine that may be busy. A launcher the resident cannot take at
# once must boot on its own without waiting long for it, and the lines it can take are served in
# parallel. The numbers (outcomes, slowest call, median call) go to the file `HECKS_HARNESS_OUT`
# names, when it is set, so a run before a change and a run after it can be compared.
RSpec.describe "a resident under concurrent launchers" do
  include ResidentLaunch

  CALLERS = 24
  BUSY_CALLERS = 48
  LINE = %w[tickets Work.undone].freeze

  # @return [Array<Array(Integer, Float)>] each launcher's exit status and seconds, all started
  #   together
  def fire(count = CALLERS)
    Array.new(count) { Thread.new { timed } }.map(&:value)
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = logged(*LINE)
    [status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  # The line through the resident, with the usage log on in the group's own cache directory.
  def logged(*argv)
    _out, _err, status = Open3.capture3(env(true).merge("HECKS_USAGE" => nil),
                                        File.join(ResidentLaunch::ROOT, "exe/hecks"), *argv, chdir: ResidentLaunch::ROOT)
    status.exitstatus
  end

  # @return [Array<Hash>] the usage log's rows
  def logged_rows
    path = File.join(@cache, "usage.jsonl")
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  # @return [Hash{String => Integer}] how the lines met the resident, from the usage log rows the
  #   scenario added
  def outcomes
    logged_rows.drop(@before).map { |row| row["resident"] || "unrecorded" }.tally
  end

  # Keeps the numbers of a scenario beside those of the others in the file the run names.
  def record(name, results)
    seconds = results.map(&:last).sort
    summary = { outcomes: outcomes, slowest: seconds.last.round(2), median: seconds[seconds.size / 2].round(2) }
    path = ENV.fetch("HECKS_HARNESS_OUT", nil)
    File.write(path, JSON.pretty_generate((File.exist?(path) ? JSON.parse(File.read(path)) : {}).merge(name => summary))) if path
    summary
  end

  def measured(name)
    @first_pid = start_resident
    @before = logged_rows.size
    results = yield
    [results, record(name, results)]
  end

  # Runs the block while one busy process per core competes for the machine.
  def loaded
    burners = Array.new(Etc.nprocessors) { Process.spawn("yes", out: File::NULL) }
    yield
  ensure
    burners.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  # Runs the block while the resident is stopped, as one that is busy with something else is to
  # a caller: it takes the connection and says nothing.
  def stopped
    pid = resident_pid
    Process.kill("STOP", pid)
    yield
  ensure
    Process.kill("CONT", pid) if pid
  end

  # Runs the block with the checkout's lockfile looking newer, then puts its modification time back.
  def changed_code
    lockfile = File.join(ResidentLaunch::ROOT, "Gemfile.lock")
    stamp = File.mtime(lockfile)
    File.utime(Time.now + 30, Time.now + 30, lockfile)
    yield
  ensure
    File.utime(stamp, stamp, lockfile)
  end

  # Waits until the resident has seen the change and retired, so the lines that follow find none.
  def retired
    ThreadParking.wait_for(timeout: 30) { !File.exist?(ResidentLaunch::PATHS.socket(ResidentLaunch::ROOT)) }
  end

  it "starts one replacement when a burst of lines arrives after the code changed, and every line answers",
     :aggregate_failures do
    results, summary = measured("changed") { changed_code { retired.then { fire(12) } } }
    expect(results.map(&:first).uniq).to eq([0])
    expect(summary[:outcomes].fetch("started", 0)).to be <= 1
  end

  it "answers every line without waiting long for a resident that says nothing", :aggregate_failures do
    results, summary = measured("stopped") { stopped { fire(12) } }
    expect(results.map(&:first).uniq).to eq([0])
    expect(summary[:outcomes].fetch("served", 0)).to eq(0)
  end

  it "answers every line and serves most of them when the machine is quiet", :aggregate_failures do
    results, summary = measured("quiet") { fire }
    expect(results.map(&:first).uniq).to eq([0])
    expect(summary[:outcomes].fetch("served", 0)).to be >= CALLERS / 2
  end

  it "answers every line and keeps the slowest near a cold boot when every core is busy", :aggregate_failures do
    results, summary = measured("busy") { loaded { fire(BUSY_CALLERS) } }
    expect(results.map(&:first).uniq).to eq([0])
    expect(summary[:slowest]).to be < 20
  end
end
