# frozen_string_literal: true

# The watchdog's process: the one file the launchd job runs. It reads the roster file, makes a pass,
# waits the declared seconds and does it again, and it boots nothing of Hecks. A pass that fails is
# journaled and the loop carries on; the job's KeepAlive restarts the process if it ends.
require "json"
require_relative "pass"

home = ARGV.fetch(0)
shell = Hecks::Adapters::Guarding::Loop::Shell.new
clock = -> { Time.now.to_i }

loop do
  roster = JSON.parse(File.read(File.join(home, "roster.json")))
  begin
    pass = Hecks::Adapters::Guarding::Loop::Pass
    pass.new(roster: roster, shell: shell, clock: clock, home: home, pause: ->(seconds) { sleep(seconds) }).run
  rescue StandardError => e
    Hecks::Adapters::Guarding::Loop::Journal.new(home, clock).add("pass_failed", "", error: "#{e.class}: #{e.message}")
  end
  sleep(roster.dig("settings", "pass_seconds").to_i)
end
