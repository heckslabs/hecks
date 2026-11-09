require "spec_helper"
require "json"
require "tmpdir"
require_relative "support/resident_launch"

# A resident does not keep the environment of whoever started it (ADR 0201): a launcher run with
# odd variables in its environment starts the same plain resident as any other, which then serves
# an ordinary caller and refuses, naming the variable, one that carries a variable the code was
# loaded without. One born under more than a plain resident has, as an older one was, is replaced
# after it refuses three callers in a minute. The processes are real; the cache directories are
# the group's own.
RSpec.describe "a resident started from an odd environment" do
  include ResidentLaunch

  # Runs a launcher line with the usage log on and the given variables added.
  def launch_logged(extra = {})
    environment = env(true).merge("HECKS_USAGE" => nil).merge(extra)
    Open3.capture3(environment, File.join(ResidentLaunch::ROOT, "exe/hecks"), "tickets", "Work.undone",
                   chdir: ResidentLaunch::ROOT)
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

  def odd = { "HECKS_FOO" => "1", "CLAUDE_CODE_SESSION_ID" => "a session", "TMPDIR" => @cache }

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue SystemCallError
    false
  end

  after { stop_resident }

  it "starts the same plain resident, which serves an ordinary caller", :aggregate_failures do
    launch_logged(odd)
    wait_for_resident
    expect(File.read(ResidentLaunch::PATHS.baseline(ResidentLaunch::ROOT)).strip).to be_empty
    launch_logged
    expect(last_outcome).to eq("served")
  end

  it "serves a caller that carries the library path the rbenv shim gives every Ruby" do
    launch_logged(odd)
    wait_for_resident
    launch_logged("RUBYLIB" => "/opt/homebrew/Cellar/rbenv/1.3.2/rbenv.d/exec/gem-rehash:")
    expect(last_outcome).to eq("served")
  end

  it "refuses a caller that carries a variable the code was loaded without, naming it" do
    launch_logged(odd)
    wait_for_resident
    launch_logged("HECKS_ENGINE" => "ruby")
    expect(last_outcome).to eq("refused:env:HECKS_ENGINE")
  end

  it "keeps a plain resident through any number of refusals", :aggregate_failures do
    pid = start_resident
    4.times { launch_logged("HECKS_ENGINE" => "ruby") }
    expect(alive?(pid)).to be(true)
    launch_logged
    expect(last_outcome).to eq("served")
  end

  # Starts a resident and says it was born under more than a plain one has, as an older one was.
  def start_atypical
    start_resident.tap { File.write(ResidentLaunch::PATHS.baseline(ResidentLaunch::ROOT), "BUNDLE_GEMFILE") }
  end

  # Waits for the old resident to end, then starts its replacement with one more line.
  def restart_after(old)
    ThreadParking.wait_for(timeout: 30) { !alive?(old) }
    launch_logged
    wait_for_new_resident(old)
  end

  it "replaces a resident that was not born plain after three refusals, then serves", :aggregate_failures do
    old = start_atypical
    3.times { launch_logged("HECKS_ENGINE" => "ruby") }
    fresh = restart_after(old)
    launch_logged
    expect([alive?(old), fresh == old, last_outcome]).to eq([false, false, "served"])
  end
end
