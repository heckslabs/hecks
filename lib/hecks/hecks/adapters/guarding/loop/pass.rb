# frozen_string_literal: true

require "json"
require_relative "shell"
require_relative "journal"
require_relative "state"
require_relative "settings"
require_relative "loops"
require_relative "vanishing"
require_relative "resuming"

module Hecks
  module Adapters
    class Guarding
      module Loop
        # One pass of the watchdog's loop, run apart from the domain: it brings the Claude daemon up
        # if it is gone, then resumes each pinned session `claude agents` lists as gone, then checks
        # the loops of the sessions it resumed. It starts and reads; it never ends a process.
        class Pass
          # @param roster [Hash] `sessions` (name, cwd, loops) and `settings`, from the roster file
          # @param shell [#capture, #detach] runs `claude`; a stand-in in specs
          # @param clock [#call] seconds since the epoch
          # @param home [String] the loop's directory
          # @param pause [#call] waits the given seconds
          def initialize(roster:, shell:, clock:, home:, pause: ->(_seconds) {})
            @sessions = roster["sessions"]
            @settings = Settings.new(roster["settings"])
            @shell = shell
            @clock = clock
            @pause = pause
            @home = home
            @journal = Journal.new(home, clock)
            @state = State.new(home)
          end

          # @return [void]
          def run
            @loops = Loops.new(@home, @sessions)
            @loops.write
            bring_up_daemon
            check_loops
            resume(gone(listed))
            @state.save
          end

          private

          def bring_up_daemon
            return if @shell.capture("claude", "daemon", "status").ok?

            @shell.detach("claude", "daemon", "run")
            @journal.add("daemon_started")
            @pause.call(3)
          end

          def listed = JSON.parse(@shell.capture("claude", "agents", "--json", "--all").out)

          def gone(entries)
            @sessions.select { |row| entries.none? { |entry| working?(entry, row) } }.map { |row| [row, last(entries, row)] }
          end

          def working?(entry, row) = entry["name"] == row["name"] && !@settings.dead_states.include?(entry["state"].to_s)

          def last(entries, row) = entries.reverse.find { |entry| entry["name"] == row["name"] }

          def resume(pairs)
            vanishing = Vanishing.new(state: @state, settings: @settings, shell: @shell, journal: @journal)
            vanishing.see(pairs.map { |row, _| row["name"] }, @clock.call)
            resuming = Resuming.new(shell: @shell, journal: @journal, settings: @settings)
            pairs.each { |row, entry| @state.resumed[row["name"]] = @clock.call if due?(row) && resuming.resume(row, entry) }
          end

          def due?(row) = @clock.call - @state.resumed.fetch(row["name"], 0) > @settings.number("loops_grace")

          def check_loops
            @state.resumed.each do |name, since|
              if @loops.armed?(name, since) then settle(name, "loops_armed")
              elsif @clock.call - since > @settings.number("loops_grace") then settle(name, "loops_missing")
              end
            end
          end

          def settle(name, kind)
            @journal.add(kind, name)
            @state.resumed.delete(name)
          end
        end
      end
    end
  end
end
