# frozen_string_literal: true

require "json"
require_relative "event_trace/summary"
require_relative "event_trace/report"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # Whether events are seen and answered: each event in a domain's log, the policies that
        # listen to it (read from the bluebooks) and what became of each delivery (read from the
        # store's outbox). Every store is opened read-only and the domain is never booted, so a
        # trace cannot claim or settle a row.
        module EventTrace
          DEFAULT_LAST = 20

          # @param domain [Hash, String] the domain directory
          # @param event [Hash, String, nil] a bare event name to trace
          # @param run [Hash, String, nil] a run key: a record's identity or its payload's `run`
          # @param last [Hash, Integer, nil] how many of the newest events to trace (default 20)
          # @param database [Hash, String, nil] keep only the stores whose location contains this
          # @return [Hash] `text:` the trace as JSON
          # @raise [Runtime::NotFound] if the directory cannot be loaded or a database refuses
          def event_trace(domain:, event: nil, run: nil, last: nil, database: nil)
            answering do
              selection = EventTrace::Selection.new(*[event, run].map { |v| plain(v) }, count(plain(last)), plain(database))
              JSON.pretty_generate(Report.new(Hecks.describe(plain(domain)).registry, selection).to_h)
            end
          end

          private

          def count(last) = last.to_s.empty? ? DEFAULT_LAST : last.to_i
        end
      end
    end
  end
end
