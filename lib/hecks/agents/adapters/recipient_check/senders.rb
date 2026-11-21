# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    class RecipientCheck
      # The names that have sent a message, read from the Agents registry. A session started by
      # hand (miette, the orchestrator, the coach) has no run, but it has a name once it speaks,
      # so a reply to it is held for it. It only reads; a boot that holds no `Message` has none.
      class Senders
        # @param registry [Runtime::Registry, nil] whose Agents bluebook holds the `Message` rows
        def initialize(registry)
          @registry = registry
        end

        # @param name [String] a recipient no run holds
        # @return [Boolean] whether a message was ever sent under that name
        def spoke?(name) = names.include?(name)

        private

        def names = rows.map { |row| StartedWork.value(row, :sender).to_s }

        def rows
          aggregate = message_aggregate
          aggregate ? @registry.repository("Agents", aggregate).all : []
        end

        def message_aggregate
          bluebook = @registry&.bluebook("Agents")
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Message" }
        end
      end
    end
  end
end
