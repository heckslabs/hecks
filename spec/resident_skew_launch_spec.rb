require "spec_helper"
require "json"
require_relative "support/resident_launch"

# A resident of an older protocol stands for the checkout, and a launcher of the current protocol
# arrives (ADR 0201). The launcher must not talk to it: it notes `refused:protocol`, boots on its
# own and starts a resident of its own, which serves the next line, while the old one is left
# alone to go idle. The processes are real; the cache directories are the group's own.
RSpec.describe "a launcher meeting a resident of another protocol" do
  include ResidentLaunch

  LINE = %w[tickets Work.undone].freeze

  # Runs a launcher line with the usage log on, under the protocol the spec process names.
  def launch_logged
    environment = env(true).merge("HECKS_USAGE" => nil)
    Open3.capture3(environment, File.join(ResidentLaunch::ROOT, "exe/hecks"), *LINE, chdir: ResidentLaunch::ROOT)
  end

  # @return [String, nil] how the last logged line met a resident
  def last_outcome
    rows = File.readlines(File.join(@cache, "usage.jsonl")).filter_map { |line| parsed(line) }
    rows.last&.fetch("resident", nil)
  end

  def parsed(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def under_protocol(number)
    saved = ENV.fetch("HECKS_RESIDENT_PROTOCOL", nil)
    ENV["HECKS_RESIDENT_PROTOCOL"] = number
    yield
  ensure
    ENV["HECKS_RESIDENT_PROTOCOL"] = saved
  end

  # Starts a resident under protocol 1, then returns its process id.
  def old_resident
    under_protocol("1") do
      launch_logged
      wait_for_resident
    end
  end

  after do
    under_protocol("1") { stop_resident }
    stop_resident
  end

  it "does not ask the old resident, notes the protocol, and starts its own", :aggregate_failures do
    old = old_resident
    launch_logged
    outcome = last_outcome
    fresh = wait_for_new_resident(old)
    expect([outcome, fresh == old, alive?(old)]).to eq(["refused:protocol", false, true])
  end

  it "serves the next line from the resident it started", :aggregate_failures do
    old = old_resident
    launch_logged
    wait_for_new_resident(old)
    launch_logged
    expect([last_outcome, alive?(old)]).to eq(["served", true])
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue SystemCallError
    false
  end
end
