# frozen_string_literal: true

require "fileutils"

module Hecks
  module QualityControlCli
    class QaTick
      # What a tick prints and logs: the sweep output condensed for stdout, the unabridged log file
      # and the closing report with the tick's exit status.
      module Output
        private

        def collapse_held_lines(text)
          text.gsub(/(?:#{HELD_SEED_LINE}\n)+/) do |run|
            count = run.lines.size
            "  (#{count} held seed(s) suppressed here — none surprised; full detail in the tick's log file)\n"
          end
        end

        # The sweep's `--all` consolidated report is the one step whose bulk section can get
        # large enough to put a relay at risk of truncation (a widened `clean_streak` means hundreds
        # of "seed N: held" lines can precede either a real finding or an unrelated operational
        # error). Everything from the first `OPERATIONAL ERRORS`/`FOUND SOMETHING` header through
        # the end of the last such block is copied verbatim, never summarized or trimmed.
        # `QA_SWEEP_TRACE` output, when present, is routine per-phase timing with no finding in it,
        # so it is left out of stdout (still in the log).
        def condense_sweep_output(raw)
          errors_at = raw.index(/^OPERATIONAL ERRORS \(/)
          found_at = raw.index(/^FOUND SOMETHING \(/)
          protect_from = [errors_at, found_at].compact.min
          return collapse_held_lines(raw) if protect_from.nil?

          trace_at = raw.index(/^QA_SWEEP_TRACE output /)
          protected_block = raw[protect_from...(trace_at || raw.length)]
          "#{collapse_held_lines(raw[0...protect_from])}#{protected_block}#{trace_note(trace_at)}"
        end

        def trace_note(trace_at)
          return "" unless trace_at

          "\n(hecks quality_control ask run's QA_SWEEP_TRACE output omitted here — routine per-phase timing, not a " \
            "finding; the full record is in the tick's log file)\n"
        end

        def write_tick_log!(pr_check_output, sweep_output, generated_output)
          dir = File.join(@root, "tmp/qa-tick-logs")
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{Time.now.strftime("%Y%m%d-%H%M%S")}-#{Process.pid}.log")
          File.write(path, <<~LOG)
            #{"=" * 72}
            hecks quality_control check_pull_requests -- full raw output
            #{"=" * 72}
            #{pr_check_output}

            #{"=" * 72}
            hecks quality_control ask run --all -- full raw output
            #{"=" * 72}
            #{sweep_output}

            #{"=" * 72}
            hecks quality_control check_generated_domains --from-dials -- full raw output
            #{"=" * 72}
            #{generated_output}
          LOG
          path
        end

        def verdict(code)
          case code
          when EXIT_OK then "clean"
          when EXIT_FOUND_SOMETHING then "FOUND SOMETHING"
          when EXIT_ERROR then "operational error"
          else "exit #{code.inspect}"
          end
        end

        def report(exits, reclaimed, log_path)
          banner "tick report"
          print_step_verdicts(exits)
          puts stale_holds_line(reclaimed)
          tick_exit = tick_exit_for(exits)
          puts "tick: #{verdict(tick_exit)} (exit #{tick_exit})"
          puts "full raw output (all three steps, unabridged): #{log_path}"
          tick_exit
        end

        def print_step_verdicts(exits)
          pr_check_exit, sweep_exit, generated_exit = exits
          puts "hecks quality_control check_pull_requests:   #{verdict(pr_check_exit)} (exit #{pr_check_exit.inspect})"
          puts "hecks quality_control ask run --all: #{verdict(sweep_exit)} (exit #{sweep_exit.inspect})"
          puts "hecks quality_control check_generated_domains: #{verdict(generated_exit)} (exit #{generated_exit.inspect})"
        end

        def stale_holds_line(reclaimed)
          named = reclaimed.empty? ? "" : " (#{reclaimed.join(", ")})"
          "stale holds reclaimed: #{reclaimed.size}#{named}"
        end

        def tick_exit_for(exits)
          return EXIT_FOUND_SOMETHING if exits.include?(EXIT_FOUND_SOMETHING)

          exits.all?(EXIT_OK) ? EXIT_OK : EXIT_ERROR
        end
      end
    end
  end
end
