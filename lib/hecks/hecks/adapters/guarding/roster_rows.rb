# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class Guarding
      # The roster as the Hecks bluebook's `Watchdog` aggregate declares it: its `PinnedSession`,
      # `WatchedLoop` and `Setting` rows, read from the booted IR and joined into the one JSON
      # document the loop reads. No row is kept anywhere else.
      class RosterRows
        # The `~` a row's directory starts with, standing for the home directory.
        HOME_MARK = /\A~/

        # @param registry [Runtime::Registry, nil] a booted registry holding the Hecks bluebook
        # @param home [String] the home directory a `~` in a row's directory stands for
        def initialize(registry, home: Dir.home)
          @aggregate = aggregate_of(registry&.bluebook("Hecks"))
          @home = home
        end

        # @return [String] the roster document: `sessions` with their `loops`, and `settings`
        def json = JSON.pretty_generate("sessions" => sessions, "settings" => settings)

        private

        def aggregate_of(bluebook) = bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Watchdog" }

        def sessions
          rows("PinnedSession").map do |row|
            { "name" => row[:name], "cwd" => row[:cwd].sub(HOME_MARK, @home), "loops" => loops(row[:name]) }
          end
        end

        def loops(name)
          rows("WatchedLoop").select { |row| row[:session] == name }
                             .map { |row| { "kind" => row[:kind], "schedule" => row[:schedule], "prompt" => row[:prompt] } }
        end

        def settings = rows("Setting").to_h { |row| [row[:key], row[:value]] }

        def rows(name)
          shape = @aggregate&.value_objects&.find { |object| object.hecks_name == name }
          Array(shape&.members).map { |row| row.to_h.transform_keys(&:to_sym) }
        end
      end
    end
  end
end
