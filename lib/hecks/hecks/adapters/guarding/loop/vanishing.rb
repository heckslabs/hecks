# frozen_string_literal: true

module Hecks
  module Adapters
    class Guarding
      module Loop
        # Notices when several pinned sessions go within one window: the moment each was first seen
        # gone is kept, and when enough fall inside the window one entry names them with a snapshot
        # of the machine's processes, so the sender of whatever ended them can be read from it.
        class Vanishing
          # @param state [State] what the loop remembers
          # @param settings [Settings] the window and the count
          # @param shell [#capture] runs `ps`
          # @param journal [Journal] where the entry goes
          def initialize(state:, settings:, shell:, journal:)
            @state = state
            @settings = settings
            @shell = shell
            @journal = journal
          end

          # @param gone [Array<String>] the pinned sessions not working now
          # @param now [Integer] the moment
          # @return [void]
          def see(gone, now)
            @state.vanished.select! { |name, _| gone.include?(name) }
            gone.each { |name| @state.vanished[name] ||= now }
            recent = @state.vanished.select { |_, at| now - at <= @settings.number("mass_kill_window") }
            note(recent, now) if mass?(recent)
          end

          private

          def mass?(recent)
            recent.size >= @settings.number("mass_kill_count") && recent.values.min > @state.noted
          end

          def note(recent, now)
            @state.noted = now
            @journal.add("mass_kill", "", sessions: recent.keys, moments: recent.values, snapshot: snapshot)
          end

          def snapshot = first_lines(@shell.capture("ps", "-axo", "pid,ppid,uid,etime,command").out)

          def first_lines(text) = text.lines.first(300).join
        end
      end
    end
  end
end
