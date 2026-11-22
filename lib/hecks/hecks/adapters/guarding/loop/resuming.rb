# frozen_string_literal: true

module Hecks
  module Adapters
    class Guarding
      module Loop
        # Resumes one pinned session by the name it is listed under, from its own directory, as the
        # `Fleet.resume!` command does: `claude --bg --resume <id> -n <name>`.
        class Resuming
          # @param shell [#capture] runs `claude` and `ps`
          # @param journal [Journal] where what it did is recorded
          # @param settings [Settings] the nice and priority that mean a session is held back
          def initialize(shell:, journal:, settings:)
            @shell = shell
            @journal = journal
            @settings = settings
          end

          # @param row [Hash] the roster row: `name` and `cwd`
          # @param entry [Hash, nil] the session `claude agents` lists under that name, if any
          # @return [Boolean] whether the session was resumed
          def resume(row, entry)
            id = session_id(entry)
            return unlisted(row["name"]) unless id

            result = @shell.capture("claude", "--bg", "--resume", id.to_s, "-n", row["name"], chdir: row["cwd"])
            @journal.add(result.ok? ? "resumed" : "resume_refused", row["name"], session: id, said: result.err.strip)
            result.ok?
          end

          # @param entry [Hash] a listed session, read again after its resume
          # @return [void]
          def priority(entry)
            pid = entry && entry["pid"]
            return unless pid

            nice, pri = niceness(pid)
            held = nice == @settings.number("held_nice") && pri == @settings.number("held_priority")
            @journal.add("held_on_efficiency_cores", entry["name"].to_s, nice: nice, priority: pri) if held
          end

          private

          def session_id(entry)
            return unless entry

            entry.key?("sessionId") ? entry["sessionId"] : entry["id"]
          end

          def niceness(pid) = ps_numbers(@shell.capture("ps", "-o", "ni=,pri=", "-p", pid.to_s).out)

          def ps_numbers(text) = text.split.map(&:to_i)

          def unlisted(name) = @journal.add("not_listed", name) && false
        end
      end
    end
  end
end
