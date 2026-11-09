module Hecks
  module Adapters
    module Driving
      module UsageLog
        # What a run says about its own start: how long the launcher took to reach the command,
        # whether that boot judged any bluebook afresh, and who ran it. Each field is optional on
        # read, so a line written before they existed still counts.
        module Telemetry
          # The variable a session sets to name itself.
          CALLER_VARIABLE = "HECKS_CALLER".freeze
          # The variable the Claude Code harness sets to the running session's id.
          SESSION_VARIABLE = "CLAUDE_SESSION_ID".freeze
          # The top-level constant a launcher defines as its first act, a monotonic clock reading.
          LAUNCHED_AT = :HECKS_LAUNCHED_AT

          module_function

          # The fields a run adds to its line.
          #
          # @param started [Float] the monotonic clock reading when the command began
          # @return [Hash{String => Object}] `boot_ms`, `cold` and `caller`, leaving out the unknown
          def fields(started)
            { "boot_ms" => boot_ms(started), "cold" => cold?, "caller" => caller_name }.compact
          end

          # @param started [Float] the monotonic clock reading when the command began
          # @return [Integer, nil] milliseconds from the launcher's first line to the command, nil
          #   when the launcher did not note its start
          def boot_ms(started)
            launched = Object.const_defined?(LAUNCHED_AT) ? Object.const_get(LAUNCHED_AT) : nil
            launched.is_a?(Float) ? ((started - launched) * 1000).round : nil
          end

          # @return [Boolean, nil] whether this process judged a bluebook the cache did not hold
          def cold?
            Hecks::Bluebook::MetaValidator::VerdictCache.misses.positive?
          rescue NameError
            nil
          end

          # @return [String, nil] the session that ran the command, when it says so
          def caller_name
            [ENV.fetch(CALLER_VARIABLE, nil), ENV.fetch(SESSION_VARIABLE, nil)].find { |name| !name.to_s.empty? }
          end

          # The runs per caller and per boot temperature in the window, as lines of text.
          #
          # @param runs [Array<Hash>] the entries in the window
          # @return [Array<String>] the `by caller` and `boot` sections, empty when no run has them
          def lines(runs)
            return [] unless runs.any? { |run| run.key?("caller") || run.key?("cold") }

            ["", "by caller:", *callers(runs), "", "boot (runs with a record of it):", *temperatures(runs)]
          end

          # @return [Array<String>] one line per caller, most runs first; others are "unnamed"
          def callers(runs)
            tally = runs.map { |run| run["caller"] || "unnamed" }.tally
            tally.sort_by { |name, count| [-count, name] }.first(15)
                 .map { |name, count| format("  %<count>6d  %<name>s", count: count, name: name) }
          end

          # @return [Array<String>] the cold and warm counts with the median boot time of each
          def temperatures(runs)
            known = runs.select { |run| run.key?("cold") }
            [true, false].map do |cold|
              temperature_line(cold ? "cold" : "warm", known.select { |run| run["cold"] == cold })
            end
          end

          # @return [String] the line for one temperature
          def temperature_line(label, runs)
            times = runs.filter_map { |run| run["boot_ms"] }.sort
            median = times.empty? ? "-" : "#{times[times.size / 2]} ms median boot"
            format("  %<count>6d  %<label>s  %<median>s", count: runs.size, label: label, median: median)
          end
        end
      end
    end
  end
end
