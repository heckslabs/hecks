module Hecks
  module Adapters
    module Driving
      module Resident
        # A resident never exits while a line it forked still runs, so a child that is stuck
        # keeps it standing past its idle time, and keeps whatever stores the child holds. Such a
        # resident says so: it writes a note beside its socket ({Paths.overdue}) that names itself
        # and each line that has run longer than the idle time, with the line's process id, when
        # it began and its first words. The note goes once no line is overdue.
        module Overdue
          # How many words of a line the note shows.
          WORDS = 3

          private

          # Notes on a line's monitor which child it waits for, since when, and for what line.
          def label(watch, pid, argv)
            line = { pid: pid, started: Time.now, words: Array(argv).first(WORDS).join(" ") }
            watch.thread_variable_set(:line, line)
          end

          # @return [Array<Hash>] the lines still running after longer than the idle time
          def overdue_lines(now)
            lines = @guard.synchronize { @monitors.select(&:alive?) }.filter_map { |watch| watch.thread_variable_get(:line) }
            lines.select { |line| now - line[:started] > @settings[:idle_seconds] }
          end

          # Writes the note when a line is overdue and its text has changed, and removes it when
          # none is.
          def note_overdue(now = Time.now)
            lines = overdue_lines(now)
            text = lines.empty? ? nil : overdue_text(lines)
            return if text == @overdue_noted

            @overdue_noted = text
            text ? Paths.put(Paths.overdue(@root), text) : Paths.forget(Paths.overdue(@root))
          end

          # @return [String] the note: the resident, then one line per overdue child
          def overdue_text(lines)
            head = "resident #{Process.pid}, up since #{@born.utc}, is past its idle time of " \
                   "#{@settings[:idle_seconds].round} seconds with a line still running:\n"
            head + lines.map { |line| "  pid #{line[:pid]} since #{line[:started].utc}: #{line[:words]}\n" }.join
          end

          # Waits for the lines still running, keeping the note current, and removes it at the end.
          def wait_for_lines
            @monitors.each { |watch| note_overdue until watch.join(Pool::UPKEEP_SECONDS) }
            Paths.forget(Paths.overdue(@root))
          end
        end
      end
    end
  end
end
