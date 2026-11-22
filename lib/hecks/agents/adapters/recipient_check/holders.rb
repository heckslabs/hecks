# frozen_string_literal: true

module Hecks
  module Adapters
    class RecipientCheck
      # The live seats that fill a name's role: the hand runs whose key or role is the name, or the
      # role a `StandingSeat` row of the Message aggregate says holds it, and whose session
      # `claude agents` lists. It only reads.
      class Holders
        # @param registry [Runtime::Registry, nil] whose Agents bluebook holds the seat rows
        # @param hand_runs [HandRuns] the registered sessions
        # @param listed [#call] answers whether `claude agents` lists a session id
        def initialize(registry, hand_runs, listed)
          @registry = registry
          @hand_runs = hand_runs
          @listed = listed
        end

        # @param name [String] a recipient with no live session
        # @return [Array<String>] the run keys of the live seats that fill it
        def for(name)
          wanted = [name, seat_role(name)].compact
          live(filling(wanted)).map { |row| row[:run] }.uniq
        end

        # @param name [String] a recipient with no live session
        # @return [String] `; live holders: a, b` for each live seat, empty when none is
        def hint(name)
          found = self.for(name)
          found.empty? ? "" : "; live holders: #{found.join(", ")}"
        end

        # @param name [String] a recipient with no live session
        # @return [String, nil] the one live seat that fills a standing seat's name, nil otherwise
        def sole(name)
          found = seat_role(name) ? self.for(name) : []
          found.first if found.one?
        end

        # @param name [String] a recipient with no live session
        # @return [String] `; held for <name> until <role> registers` for a standing seat, else empty
        def waiting(name)
          role = seat_role(name)
          role ? "; held for #{name} until #{role} registers" : ""
        end

        private

        def filling(wanted)
          @hand_runs.registered.select { |row| wanted.include?(row[:run]) || wanted.include?(row[:role]) }
        end

        def live(rows) = rows.select { |row| !row[:session].empty? && @listed.call(row[:session]) }

        def seat_role(name) = seats.find { |row| row[:name] == name }&.fetch(:held_by, nil)

        def seats = Array(standing_seat&.members).map { |row| row.to_h.transform_keys(&:to_sym) }

        def standing_seat = message&.value_objects&.find { |item| item.hecks_name == "StandingSeat" }

        def message
          bluebook = @registry&.bluebook("Agents")
          bluebook&.aggregates&.find { |item| item.hecks_name == "Message" }
        end
      end
    end
  end
end
