require "time"

module Hecks
  module Adapters
    module Driving
      module UsageLog
        # How a run met the checkout's resident, and what `hecks usage` says of it. A row carries
        # `resident` (`served`, `none`, `started`, `bypass`, `unstable` or `refused:<reason>`, from
        # `Resident::Outcome`), so a measurement can say why a boot was slow, not only that it was.
        # A row written before the field existed has none and counts under `unrecorded`.
        module Residency
          # The variable the launcher's client notes the outcome in. It is the same name as
          # `Resident::Outcome::VARIABLE`, spelled here so reading it needs no resident code.
          VARIABLE = "HECKS_RESIDENT_OUTCOME".freeze
          # What a row that has no outcome counts under.
          UNRECORDED = "unrecorded".freeze
          # The outcome of a line a resident's child ran.
          SERVED = "served".freeze
          # Seconds in the hour the by-caller count covers.
          HOUR = 3600

          module_function

          # @return [String, nil] the outcome this process was told, at most 64 characters
          def outcome
            value = ENV.fetch(VARIABLE, "")
            value.empty? ? nil : value[0, 64]
          end

          # @return [Boolean] whether a resident's child is running this line
          def served? = outcome == SERVED

          # The resident section of `hecks usage`: runs and median boot per outcome, the share
          # served, the reasons a resident refused, and the launcher boots per caller in the last
          # hour.
          #
          # @param runs [Array<Hash>] the entries in the window
          # @param now [Time] where the last hour ends
          # @return [Array<String>] the lines, empty when no run has an outcome
          def lines(runs, now: Time.now.utc)
            return [] unless runs.any? { |run| run.key?("resident") }

            ["", "resident (outcome of each run):", *outcomes(runs), *share(runs), *reasons(runs),
             "", "boots in the last hour, by caller:", *hourly(runs, now)]
          end

          # @return [Array<String>] one line per outcome, most runs first, with its median boot
          def outcomes(runs)
            groups = runs.group_by { |run| run["resident"] || UNRECORDED }
            groups.sort_by { |name, rows| [-rows.size, name] }.map do |name, rows|
              format("  %<count>6d  %-24<name>s %<median>s", count: rows.size, name: name, median: median(rows))
            end
          end

          # @return [String] the median boot time of the rows that recorded one
          def median(rows)
            times = rows.filter_map { |run| run["boot_ms"] }.sort
            times.empty? ? "-" : "#{times[times.size / 2]} ms median boot"
          end

          # @return [Array<String>] the share of recorded runs a resident served
          def share(runs)
            known = runs.select { |run| run.key?("resident") }
            served = known.count { |run| run["resident"] == SERVED }
            [format("  served: %<served>d of %<known>d recorded runs (%<percent>d%%)",
                    served: served, known: known.size, percent: (100.0 * served / known.size).round)]
          end

          # @return [Array<String>] the reasons a resident was asked or could have been, and did not
          #   serve, most often first
          def reasons(runs)
            ranked = refusals(runs).tally.sort_by { |why, n| [-n, why] }.first(8)
            return [] if ranked.empty?

            ["  refused because:", *ranked.map { |why, n| format("    %<n>6d  %<why>s", n: n, why: why) }]
          end

          # @return [Array<String>] the reason of each run a resident refused
          def refusals(runs)
            words = runs.map { |run| run["resident"].to_s }
            words.select { |word| word.start_with?("refused:") }.map { |word| word.delete_prefix("refused:") }
          end

          # @return [Array<String>] the runs with a time inside the last hour, per caller
          def hourly(runs, now)
            recent = runs.select { |run| recent?(run, now) }
            tally = recent.map { |run| run["caller"] || "unnamed" }.tally
            return ["  none recorded"] if tally.empty?

            ranked = tally.sort_by { |name, n| [-n, name] }.first(15)
            ranked.map { |name, n| format("  %<n>6d  %<name>s", n: n, name: name) }
          end

          # @return [Boolean] whether the run has a time and it falls in the hour before `now`
          def recent?(run, now)
            at = Time.iso8601(run["at"].to_s)
            at.between?(now - HOUR, now)
          rescue ArgumentError
            false
          end
        end
      end
    end
  end
end
