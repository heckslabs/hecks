# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      module AllMode
        # The consolidated report `--all` prints once every wave is done: what each child resolved,
        # then its operational errors and findings verbatim.
        module Report
          # Every child prints one `resolved depth:` line; the child's log is the single source of
          # truth that the report prints verbatim, so scraping it here cannot disagree.
          RESOLVED_DEPTH_LINE = /^resolved depth: seeds=(\d+) steps=(\d+) \(clean_streak=(\d+)\)$/

          # Parsed from a child's `resolved modes:` line; wave-2 candidates come from the parent's
          # own inference, not from this.
          RESOLVED_MODES_LINE = /^resolved modes: (\S*) \(capabilities=([^;)]*)(?:; deferred=([^)]*))?\)$/

          private

          def resolved_depth_for(output)
            match = output.match(RESOLVED_DEPTH_LINE)
            return "depth unknown (target errored before it could claim)" unless match

            "#{match[1]} seeds x #{match[2]} steps (clean streak #{match[3]})"
          end

          def resolved_modes_for(output)
            match = output.match(RESOLVED_MODES_LINE)
            return "modes unknown (target errored before it could resolve them)" unless match

            line = "#{match[1].empty? ? "none" : match[1]} (capabilities: #{match[2].empty? ? "none" : match[2]}"
            line += "; deferred: #{match[3]}" if match[3] && !match[3].empty?
            "#{line})"
          end

          def print_resolved_modes(results)
            return if results.empty?

            puts
            puts "resolved modes (by target):"
            results.each { |r| puts "  #{r[:target]}: #{resolved_modes_for(r[:output])}" }
          end

          def print_resolved_depths(results)
            return if results.empty?

            puts
            puts "resolved depth (by target):"
            results.each { |r| puts "  #{r[:target]}: #{resolved_depth_for(r[:output])}" }
          end

          def print_operational_errors(errored)
            return if errored.empty?

            puts
            puts "OPERATIONAL ERRORS (#{errored.size}) — read each message, fix the actual problem, don't retry blind:"
            errored.each do |r|
              label = r[:exit_status] ? "exit #{r[:exit_status]}" : "killed by signal #{r[:termsig]}"
              puts
              puts "-- #{r[:target]} (#{label}) --"
              puts r[:output].strip
            end
          end

          def print_found_something(found)
            return if found.empty?

            puts
            puts "FOUND SOMETHING (#{found.size}) — full report per target below; act on every one:"
            found.each do |r|
              puts
              puts "#" * 72
              puts "# #{r[:target]}"
              puts "#" * 72
              puts r[:output]
            end
          end

          def print_all_mode_report(results, elapsed, clean, found, errored)
            print_all_mode_header(results, elapsed)
            puts "clean (#{clean.size}): #{clean.empty? ? "none" : clean.map { |r| r[:target] }.join(", ")}"
            print_resolved_depths(results)
            print_resolved_modes(results)
            print_operational_errors(errored)
            print_found_something(found)
            print_trace_output(results)
          end

          def print_all_mode_header(results, elapsed)
            puts "=" * 72
            puts "CONSOLIDATED REPORT — #{results.size} target(s) swept, #{elapsed.round(1)}s wall-clock " \
                 "(genuinely parallel — not the sum of every target's own sweep time)"
            puts "=" * 72
            puts
          end

          # A clean child's trace would otherwise be discarded; shown only under `QA_SWEEP_TRACE=1`.
          def print_trace_output(results)
            return unless @trace_enabled
            return if results.empty?

            puts
            puts "QA_SWEEP_TRACE output (by target, in sweep order):"
            results.each do |r|
              trace_lines = r[:output].lines.grep(/^\[qa_sweep_trace /)
              next if trace_lines.empty?

              puts "  #{r[:target]}:"
              trace_lines.each { |line| puts "    #{line.chomp}" }
            end
          end

          # A finding outranks operational errors: 2 if any child found something, else 1 if any
          # errored.
          def all_mode_exit_code(found, errored)
            return EXIT_FOUND_SOMETHING unless found.empty?
            return EXIT_ERROR unless errored.empty?

            EXIT_OK
          end
        end
      end
    end
  end
end
