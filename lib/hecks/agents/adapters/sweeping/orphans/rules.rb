# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      class Orphans
        # What makes a process a leftover, and what is stopped with it.
        #
        # A launcher is a leftover when it is an `exe/hecks` invocation (the script run directly,
        # under `ruby`, or under `bundle exec ruby`; never a command that only names the path), its
        # parent is init or gone, it is older than half an hour, and it is not a job that runs
        # detached on purpose. A rehearsal push is a leftover when its processes name the rehearsal
        # directory and are older than a day.
        class Rules
          # How long a parentless launcher may run before it is a leftover, in seconds.
          LAUNCHER_AGE = 1800
          # How long a rehearsal push may stay before it is a leftover, in seconds.
          FIXTURE_AGE = 86_400
          # A launcher invocation: the command starts with the script, `ruby` or
          # `bundle exec ruby`.
          LAUNCHER = %r{\A(?:\S*/)?(?:bundle\s+exec\s+)?(?:ruby\s+(?:-\S+(?:\s+[^-\s]\S*)?\s+)*)?(?:\S*/)?exe/hecks(?:\s|\z)}
          # Launchers that run detached or for a long time on purpose: servers, the push train, the
          # QA and catcher ticks, a gate, a spec run, a landing and a wait on an event.
          KEPT = /serve!|present!|compose!|preview!|\bmcp\b|mcp!|SendTrain|send_train|sweep\.tick|quality_control|
                  Operation\.(run|follow)|gate_run|run_impacted_specs|run_spec_|push_rehearsal|landing\.(land|finish|train)|
                  agent_?run\.check_all/ix
          # What a leftover launcher's children keep running: a session and a build are not stopped
          # with the launcher that started them. It is the program a process runs that counts, the
          # first word of its command (past a `nice`), not any word in it: a command that only
          # mentions `.claude/` or `cargo` in an argument is not one.
          KEEP_BELOW = Regexp.union(
            %r{\A(?:nice(?:\s+-n\s*\d+)?\s+)?(?:\S*/)?(?:claude|cargo|rustc)(?=\s|\z)},
            %r{\A\S*/claude/versions/\S+},
            %r{\A\S*/ClaudeCode\.app/}
          )
          # The marker a push rehearsal puts in its temp directory and in its processes' command
          # lines.
          # Only the spec of the isolated push makes such a directory; the train pushes from a
          # throwaway worktree that carries no such name.
          FIXTURE = "hecks-isolated-push"
          # The git process that started a rehearsal: a `git` command that pushes.
          PUSH = /\Agit\b.*\bpush\b/

          # @param table [ProcessTable] the process table
          # @param entries [Array<ProcessTable::Entry>] its processes
          def initialize(table:, entries:)
            @table = table
            @entries = entries
          end

          # @return [Array<ProcessTable::Entry>] the launchers and pushes that are leftovers
          def leftovers = launchers + fixtures

          # @return [Array<ProcessTable::Entry>] what a sweep stops: each leftover and what runs
          #   below it
          def stoppable
            launchers.flat_map { |entry| [entry] + below(entry, keeping: true) }.concat(
              fixtures.flat_map { |entry| [entry] + below(entry, keeping: false) }
            ).uniq(&:pid)
          end

          private

          def launchers
            alive = @entries.map(&:pid)
            @entries.select { |entry| launcher?(entry) && unattended?(entry, alive) }
          end

          def launcher?(entry)
            entry.command.match?(LAUNCHER) && !entry.command.match?(KEPT) && entry.age > LAUNCHER_AGE
          end

          def unattended?(entry, alive) = (entry.ppid == 1 || !alive.include?(entry.ppid)) && !mine.include?(entry.pid)

          def fixtures
            found = @entries.select { |entry| entry.command.include?(FIXTURE) && entry.age > FIXTURE_AGE }
            (found + pushes(found)).uniq(&:pid).reject { |entry| mine.include?(entry.pid) }
          end

          def pushes(found)
            @entries.select { |entry| entry.command.match?(PUSH) && found.any? { |kid| kid.ppid == entry.pid } }
          end

          def below(entry, keeping:)
            kids = @table.below(entry.pid, @entries)
            return kids unless keeping

            kept = kids.select { |kid| kid.command.match?(KEEP_BELOW) }.flat_map { |kid| [kid] + @table.below(kid.pid, @entries) }
            kids.reject { |kid| kept.any? { |held| held.pid == kid.pid } }
          end

          def mine = (@mine ||= ancestry([Process.pid]))

          def ancestry(chain)
            parent = @entries.find { |entry| entry.pid == chain.last }&.ppid
            parent && parent > 1 && !chain.include?(parent) ? ancestry(chain + [parent]) : chain
          end
        end
      end
    end
  end
end
