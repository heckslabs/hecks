# frozen_string_literal: true

require "time"
require "securerandom"
require "hecks/runtime/event"

module Hecks
  module Adapters
    module PipelineBoard
      # Appends the `GlanceRead` event of the `Look` command to the registry's event log when the
      # `Glance` is read. The log is the one the event tap observes, so each read is one tap line;
      # a registry with no log (a read-only boot) records nothing and the read still answers.
      module GlanceTap
        EVENT = "GlanceRead"

        module_function

        # @param registry [Runtime::Registry, nil] the registry whose event log is appended to
        # @param now [Time] the time of the read
        # @return [Runtime::EventLog, nil] the log the event was appended to, nil when there is none
        def record(registry, now)
          log = registry.respond_to?(:event_log) ? registry.event_log : nil
          log && (log << event(now))
        end

        # @return [Hecks::Runtime::Event] the read as an event of the PipelineBoard aggregate
        def event(now)
          key = SecureRandom.hex(4)
          Runtime::Event.new(name: EVENT, aggregate: "PipelineBoard", id: key, payload: { run: { value: key } },
                             occurred_at: now.utc.iso8601, correlation: {}).tap(&:emit!)
        end
      end
    end
  end
end
