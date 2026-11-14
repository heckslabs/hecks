# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    class Ticking
      # What the chain says to the launcher and to its log: a tick, a stop, a line. Every dispatch
      # names its caller (`HECKS_CALLER=ticker`), so the usage record and the board count the
      # clock's boots under its name.
      class Dispatcher
        # The caller name the launcher's usage record shows.
        CALLER = { "HECKS_CALLER" => "ticker" }.freeze

        # @param run [String] the ticker's key
        # @param launcher [String] path of `exe/hecks`
        # @param log [String] the chain's log file
        def initialize(run, launcher, log)
          @run = run
          @launcher = launcher
          @log = log
        end

        # Appends a timestamped line to the log.
        def note(line)
          File.open(@log, "a") { |f| f.puts("#{Time.now.utc.strftime("%FT%TZ")} #{line}") }
        end

        # Dispatches one tick.
        # @return [String, nil] nil when it was accepted, else the refusal's first line
        def tick(count)
          argv = ["Ticker.tick!", "to=#{@run}", "tick=#{@run}-#{count}", "beats=#{count}"]
          out, status = Open3.capture2e(CALLER, @launcher, *argv)
          note("tick #{count}: exit #{status.exitstatus.inspect}")
          status.success? ? nil : refusal(out, status)
        end

        # Records the chain's end as an event.
        def stop(why)
          note("ended: #{why}")
          out, status = Open3.capture2e(CALLER, @launcher, "Ticker.stop!", "to=#{@run}", "ending=#{why}")
          File.open(@log, "a") { |f| f.write(out) }
          note("stop exit #{status.exitstatus.inspect}")
        end

        private

        def refusal(out, status)
          why = first_refusal(out)
          why.empty? ? "the launcher exited #{status.exitstatus.inspect} without a refusal" : why
        end

        def first_refusal(out)
          lines = out.lines.map(&:strip)
          lines.find { |line| !line.empty? && !line.start_with?("[hecks]") }.to_s
        end
      end
    end
  end
end
