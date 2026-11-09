require "fileutils"
require "json"
require_relative "usage_cache"
require_relative "usage_log/telemetry"

module Hecks
  module Adapters
    module Driving
      # Keeps a local record of the commands and queries a launcher runs, so the everyday list and
      # the timing of a deprecation rest on what people type rather than on a guess.
      #
      # A run appends one JSON line to `usage.jsonl` in the directory `UsageCache` already uses:
      # the name as typed, the name it resolved to, the exit status, the duration in milliseconds,
      # the date and the time, and (`Telemetry`) the boot time, whether the boot was cold, the
      # caller, and how the line met the checkout's resident (`Residency`).
      # No arguments, values or paths are written. The record is on unless
      # `HECKS_USAGE=off` is set or a `usage.off` marker sits in that directory. The first run that
      # writes prints one line on standard error saying so, then leaves a `usage.noticed` marker.
      # Writing never fails the command it records.
      module UsageLog
        # The file each run appends its line to.
        FILE = "usage.jsonl".freeze
        # The variable that turns the record off when set to `off`.
        OPT_OUT_VARIABLE = "HECKS_USAGE".freeze
        # The marker file that turns the record off.
        OPT_OUT_MARKER = "usage.off".freeze
        # The marker file that says the first-run notice has been printed.
        NOTICE_MARKER = "usage.noticed".freeze
        # The line printed once, on the first run that writes.
        NOTICE = "hecks keeps a local record of the commands it runs in %s; set HECKS_USAGE=off to stop.".freeze
        # The window `summary` counts when none is given, in days.
        DEFAULT_WINDOW = 30
        # Seconds in a day.
        DAY = 24 * 60 * 60

        module_function

        # Appends the line for one run, unless the record is off.
        #
        # @param argv [Array<String>] the command line as typed
        # @param resolved [String, nil] the name the runner resolved it to
        # @param status [Integer] the exit status the run answered
        # @param started [Float] the monotonic clock reading when the run began
        # @return [void]
        def record(argv:, resolved:, status:, started:)
          return unless enabled?

          FileUtils.mkdir_p(directory)
          notice
          append(line(argv, resolved, status, started))
        rescue StandardError
          nil
        end

        # @return [Boolean] whether a run is recorded
        def enabled?
          ENV[OPT_OUT_VARIABLE].to_s != "off" && !File.exist?(marker(OPT_OUT_MARKER))
        end

        # Prints the first-run line once, then leaves its marker.
        def notice
          return if File.exist?(marker(NOTICE_MARKER))

          warn(format(NOTICE, path))
          FileUtils.touch(marker(NOTICE_MARKER))
        end

        # The entry for one run.
        #
        # @return [Hash] the fields `record` writes
        def line(argv, resolved, status, started)
          { "typed" => typed(argv), "resolved" => resolved, "status" => status,
            "ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
            "date" => Time.now.utc.strftime("%Y-%m-%d"),
            "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }.merge(Telemetry.fields(started))
        end

        # The name the person typed: the first word that is not a flag, past a `query` word.
        #
        # @return [String, nil]
        def typed(argv)
          words = argv.reject { |word| word.start_with?("-") }
          words.shift if CliRunner::QUERY_WORDS.include?(words.first)
          words.first
        end

        # Writes one entry as a line of the file.
        def append(entry)
          File.open(path, "a") { |file| file.puts(JSON.generate(entry)) }
        end

        # The entries on file, oldest first. A line that does not parse is skipped.
        #
        # @return [Array<Hash>]
        def entries
          File.readlines(path).filter_map { |line| JSON.parse(line) }
        rescue SystemCallError, JSON::ParserError
          []
        end

        # Counts the runs in the window and names the known ones that did not run in it.
        #
        # @param known [Array<String>] every name the launcher answers to, as the projection names
        #   them
        # @param window [Integer] how many days back a run counts
        # @return [String] the text `hecks usage` prints
        def summary(known:, window: DEFAULT_WINDOW)
          runs = runs_since(window)
          counts = resolved_names(runs)
          unrun = known.sort - counts.keys
          ["runs in the last #{window} days, most used first:", *tally_lines(counts),
           *Telemetry.lines(runs), *Residency.lines(runs),
           "", "never run in that window:", *unrun.map { |name| "  #{name}" }].join("\n")
        end

        # @return [Array<Hash>] the entries dated inside the window
        def runs_since(window)
          since = (Time.now.utc - (window * DAY)).strftime("%Y-%m-%d")
          entries.select { |entry| entry["date"].to_s >= since }
        end

        # How often each resolved name ran since the window opened.
        #
        # @return [Hash{String => Integer}]
        def counts_since(window)
          resolved_names(runs_since(window))
        end

        # @return [Hash{String => Integer}] how many runs resolved to each name
        def resolved_names(runs)
          runs.map { |entry| entry["resolved"] }.compact.tally
        end

        # @return [Array<String>] one line per name that ran, most used first
        def tally_lines(counts)
          ranked = counts.sort_by { |name, count| [-count, name] }
          ranked.map { |name, count| format("  %<count>4d  %<name>s", count: count, name: name) }
        end

        # @return [String] the file the record lives in
        def path
          File.join(directory, FILE)
        end

        # @return [String] the directory the record lives in: the usage cache's own
        def directory
          UsageCache.directory
        end

        # @return [String] a marker file in the directory
        def marker(name)
          File.join(directory, name)
        end
      end
    end
  end
end
