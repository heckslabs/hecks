require "spec_helper"
require_relative "support/resident_launch"

# `exe/hecks` through the resident of its checkout (ADR 0201): the same answers as a launcher
# that boots on its own, in a fraction of the time, surviving the resident's death and noticing
# its code change. Each group uses cache directories of its own, so no developer's resident or
# usage log is reached.
RSpec.describe "a launcher through its resident" do
  include ResidentLaunch

  # A line a cold launcher spends its whole boot on, so the resident has something to save.
  SLOW = %w[tickets Work.undone].freeze
  LINES = [%w[--help], %w[RedFlag.status], %w[RedFlag.nonsense], %w[no_such_command]].freeze

  # What the lines answer when the launcher boots on its own, after one run has filled the help
  # cache.
  def cold_answers
    LINES.each { |line| launch(*line, resident: false) }
    LINES.map { |line| launch(*line, resident: false).to_a }
  end

  # What the lines answer through the resident.
  def resident_answers = LINES.map { |line| launch(*line).to_a }

  it "answers every line with the output, the error and the exit status of a launcher that boots alone" do
    expected = cold_answers
    start_resident
    expect(resident_answers).to eq(expected)
  end

  it "answers a line in less than half the time a cold boot takes" do
    start_resident
    warm = [timed(*SLOW), timed(*SLOW)].min
    expect(warm).to be < timed(*SLOW, resident: false) / 2
  end

  it "keeps the resident standing across lines, one process serving them all", :aggregate_failures do
    pid = start_resident
    3.times { launch("RedFlag.status") }
    expect(resident_pid).to eq(pid)
    expect(File.socket?(ResidentLaunch::PATHS.socket(ResidentLaunch::ROOT))).to be(true)
  end

  it "answers the line and starts a new resident when its code has changed", :aggregate_failures do
    pid = start_resident
    with_newer_lockfile { expect(launch("RedFlag.status").status).to eq(0) }
    expect(wait_for_new_resident(pid)).not_to eq(pid)
  end

  it "answers the line at the cost of one cold boot when the resident was killed", :aggregate_failures do
    pid = start_resident
    Process.kill("KILL", pid)
    expect(launch("RedFlag.status").out).to include("main is")
    expect(wait_for_new_resident(pid)).not_to eq(pid)
  end

  it "leaves one resident when two first lines arrive together", :aggregate_failures do
    stop_resident
    answers = Array.new(2) { Thread.new { launch("RedFlag.status") } }.map(&:value)
    expect(answers.map(&:status)).to eq([0, 0])
    wait_for_resident
    expect(Dir.glob(File.join(ResidentLaunch::PATHS.directory, "*.pid")).size).to eq(1)
  end

  it "neither asks for a resident nor starts one when HECKS_NO_RESIDENT is set", :aggregate_failures do
    stop_resident
    expect(launch("--help", resident: false).status).to eq(0)
    ThreadParking.elapse(1)
    expect(resident_pid).to be_nil
  end
end
