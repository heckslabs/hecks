# frozen_string_literal: true

# The watchdog's process: the one file the launchd job runs. It reads the roster file, makes a pass,
# waits the declared seconds and does it again, and it boots nothing of Hecks. A pass that fails is
# journaled and the loop carries on; the job's KeepAlive restarts the process if it ends.
require "json"
require_relative "pass"

module Hecks
  module Adapters
    class Guarding
      module Loop
        # The forever loop over {Pass}.
        module Watch
          module_function

          # @param home [String] the loop's directory, where the roster file is
          # @return [void]
          def run(home)
            clock = -> { Time.now.to_i }
            loop do
              roster = JSON.parse(File.read(File.join(home, "roster.json")))
              once(roster, clock, home)
              sleep(roster.dig("settings", "pass_seconds").to_i)
            end
          end

          # @return [void]
          def once(roster, clock, home)
            pause = ->(seconds) { sleep(seconds) }
            Pass.new(roster: roster, shell: Shell.new, clock: clock, home: home, pause: pause).run
          rescue StandardError => e
            Journal.new(home, clock).add("pass_failed", "", error: "#{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end

Hecks::Adapters::Guarding::Loop::Watch.run(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
