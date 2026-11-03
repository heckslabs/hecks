# frozen_string_literal: true

require "json"
require "hecks/hecks/adapters/in_process_boot"

module Hecks
  module QualityControlCli
    class QaEventPump
      # Reads a domain's event log past a cursor through the `Operation.Follow` query, and turns
      # each entry back into an event a policy can react to.
      module Reader
        module_function

        # @param dir [String] the directory of the domain whose log is read
        # @param position [Integer] the count of entries already read
        # @return [Hash] `cursor:` the count now read to, and `events:` the entries past `position`
        #   (each with its payload as JSON text, as the query answers it)
        def after(dir, position)
          Hecks::Adapters::InProcessBoot.new.follow(domain: dir, since: position, wait: 0)
        end

        # @param entry [Hash] one entry the query answered
        # @return [Hecks::Runtime::Event] the event, with its payload parsed back to a hash
        def event(entry)
          Hecks::Runtime::Outbox.event_from(entry.merge("payload" => JSON.parse(entry["payload"])))
        end
      end
    end
  end
end
