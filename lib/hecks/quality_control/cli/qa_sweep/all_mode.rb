# frozen_string_literal: true

require "tempfile"
require_relative "../child"

module Hecks
  module QualityControlCli
    class QaSweep
      # `--all`: one child sweep per waiting target, in parallel, then the later waves and one
      # consolidated report.
      #
      # A child is a fresh process, never a fork: a forked child would share this process's live
      # Postgres socket.
      module AllMode
        # Every child prints one `resolved depth:` line; the child's log is the single source of
        # truth that the report prints verbatim, so scraping it here cannot disagree.
        RESOLVED_DEPTH_LINE = /^resolved depth: seeds=(\d+) steps=(\d+) \(clean_streak=(\d+)\)$/

        # Parsed from a child's `resolved modes:` line; wave-2 candidates come from the parent's own
        # inference, not from this.
        RESOLVED_MODES_LINE = /^resolved modes: (\S*) \(capabilities=([^;)]*)(?:; deferred=([^)]*))?\)$/

        private

        # Sweeps every waiting target and reports.
        #
        # @param modes [Array<Symbol>] the enabled modes each child is told
        # @param parity_wave [Boolean] whether a `persistence_parity` wave follows a clean wave 1
        # @param deferred_wave_modes [Array<Symbol>] the modes that get a wave of their own
        # @return [Integer] 2 when any child found something, else 1 when any errored, else 0
        def run_all_mode(modes:, parity_wave:, deferred_wave_modes:)
          now = Time.now.to_i
          waiting = query("Target.Rotation").map { |row| row[:reference][:value] }
          stale = stale_holds(now)
          targets = waiting + stale.map { |row| row[:reference][:value] }
          if targets.empty?
            puts "rotation is empty — nothing waiting to sweep, and no stale hold to reclaim. Clean no-op."
            return EXIT_OK
          end

          announce_all(targets, stale, modes, now)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          results = run_pool(targets) do |reference|
            spawn_sweep_child(reference, @seeds_override, @steps_override, @self_consistency, modes: modes)
          end
          results = results.map { |r| r.merge(wave: 1) }
          results += run_parity_wave(results) if parity_wave
          # Each enabled deferred mode gets its own wave over wave 1's clean targets.
          deferred_wave_modes.each do |mode|
            results += run_deferred_wave(results.select { |r| r[:wave] == 1 }, mode)
          end
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

          clean = results.select { |r| r[:exit_status] == EXIT_OK }
          found = results.select { |r| r[:exit_status] == EXIT_FOUND_SOMETHING }
          errored = results.reject { |r| [EXIT_OK, EXIT_FOUND_SOMETHING].include?(r[:exit_status]) }
          print_all_mode_report(results, elapsed, clean, found, errored)
          all_mode_exit_code(found, errored)
        end

        def announce_all(targets, stale, modes, now)
          puts "sweeping #{targets.size} target(s), at most #{@max_parallel} at once: #{targets.join(", ")} " \
               "(adversarial fraction #{@adversarial}, self-consistency #{@self_consistency}, " \
               "role draw #{@role_draw}, dry-run fraction #{@dry_run}, enabled modes #{modes.join(",")})"
          stale.each do |row|
            puts "reclaimed stale hold: #{row[:reference][:value]} (held by #{row[:held_by][:value]}, " \
                 "#{now - row[:claimed_at][:value]}s ago)"
          end
          puts
        end

        # `Target.Rotation` lists only waiting targets, so stale holds are found here:
        # `Target.Claim`'s given (claimed_at + window <= now) restated in Ruby, since a `where`
        # cannot add two fields.
        def stale_holds(now)
          query("Target.Held").select { |row| row[:claimed_at][:value] + row[:window][:value] <= now }
        end

        # Spawns `hecks quality_control query sweep.run target=<target>` as a fresh process, not a
        # fork. Seeds/steps forward only when given, so each child derives its own depth from its
        # own streak.
        def spawn_sweep_child(target_reference, seeds_override, steps_override, self_consistency,
                              modes:, parity: false)
          # Unlinked at once: the open fd stays readable, nothing is left on disk, and no fixed path
          # collides.
          log = Tempfile.new(["qa_sweep-#{filesystem_safe_component(target_reference)}-", ".log"])
          log.unlink

          args = [target_reference]
          args += ["--seeds", seeds_override.to_s] if seeds_override
          args += ["--steps", steps_override.to_s] if steps_override
          args += ["--adversarial", @adversarial.to_s, "--self-consistency", self_consistency.to_s]
          args += ["--role-draw", @role_draw.to_s, "--dry-run", @dry_run.to_s]
          args += parity ? ["--persistence-parity"] : ["--modes", modes.join(",")]

          pid = Process.spawn(*Child.argv(@root, "qa_sweep", *args), out: log, err: log, chdir: @root)
          { target: target_reference, pid: pid, log: log }
        end

        def collect_sweep_child(child, status)
          child[:log].rewind
          output = child[:log].read
          child[:log].close

          { target: child[:target], exit_status: status.exitstatus, termsig: status.termsig, output: output }
        end

        # Keeps at most `@max_parallel` children alive; results come back in queue order so reports
        # are stable.
        def run_pool(targets)
          pending = targets.dup
          running = {}
          results = {}

          until pending.empty? && running.empty?
            while running.size < @max_parallel && (next_target = pending.shift)
              child = yield(next_target)
              running[child[:pid]] = child
            end

            pid, status = Process.wait2(-1)
            child = running.delete(pid)
            next unless child

            results[child[:target]] = collect_sweep_child(child, status)
          end

          targets.map { |target| results.fetch(target) }
        end

        # Wave 2: `--persistence-parity` children for wave-1 targets that came back clean and infer
        # `postgres_era`. Skipped by `--no-parity` or when `--modes` already named the mode.
        def run_parity_wave(wave1)
          candidates = wave_candidates(wave1, :persistence_parity)
          if candidates.empty?
            puts "parity wave: no clean target binds PostgresEra — nothing to compare Memory against. Skipped."
            return []
          end

          puts
          puts "parity wave: Memory vs real PostgresEra for #{candidates.size} target(s), " \
               "at most #{@max_parallel} at once: #{candidates.join(", ")}"
          results = run_pool(candidates) do |reference|
            spawn_sweep_child(reference, @seeds_override, nil, false, modes: [], parity: true)
          end
          # Labelled in the target column so every report section tells a wave-2 row from wave 1's.
          results.map { |r| r.merge(wave: 2, target: "#{r[:target]} [parity wave]") }
        end

        # Later wave for deferred modes (era_boundary, concurrency): `--modes <mode>` children over
        # the clean wave-1 targets whose capabilities make the mode eligible.
        def run_deferred_wave(wave1, mode)
          candidates = wave_candidates(wave1, mode)
          if candidates.empty?
            puts "#{mode} wave: no clean target qualifies. Skipped."
            return []
          end

          puts
          puts "#{mode} wave: #{candidates.size} target(s), at most #{@max_parallel} at once: #{candidates.join(", ")}"
          results = run_pool(candidates) do |reference|
            spawn_sweep_child(reference, @seeds_override, nil, false, modes: [mode])
          end
          results.map { |r| r.merge(wave: 2, target: "#{r[:target]} [#{mode} wave]") }
        end

        # @return [Array<String>] the clean wave-1 targets whose capabilities make `mode` eligible
        def wave_candidates(wave1, mode)
          clean_refs = wave1.select { |r| r[:exit_status] == EXIT_OK }.map { |r| r[:target] }
          rows = query("Target.All").select { |row| clean_refs.include?(row[:reference][:value]) }
          eligible = rows.select do |row|
            capabilities = Hecks::Fuzzing::TargetCapabilities.infer(resolve_target_path(row[:path][:value]),
                                                                    rust_dir: @rust_dir)
            Hecks::Fuzzing::TargetCapabilities.eligible?(mode, capabilities)
          end
          eligible.map { |row| row[:reference][:value] }
        end

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
          puts "=" * 72
          puts "CONSOLIDATED REPORT — #{results.size} target(s) swept, #{elapsed.round(1)}s wall-clock " \
               "(genuinely parallel — not the sum of every target's own sweep time)"
          puts "=" * 72
          puts
          puts "clean (#{clean.size}): #{clean.empty? ? "none" : clean.map { |r| r[:target] }.join(", ")}"

          print_resolved_depths(results)
          print_resolved_modes(results)
          print_operational_errors(errored)
          print_found_something(found)
          print_trace_output(results)
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
