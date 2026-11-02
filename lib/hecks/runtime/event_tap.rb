# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "event"

module Hecks
  module Runtime
    # An opt-in, append-only local log of what the runtime dispatched: one JSON line per event and
    # one per policy delivery. It exists for the domains that persist nothing (Memory keeps no
    # journal), so a reader such as the PipelineBoard can still see them.
    #
    # It is off unless a world declares it: `event_log "EventTap", path: "...", max_bytes: N`. A
    # client's world declares nothing, so a client writes no file. The log holds names, identities
    # and outcomes, never payloads. A write that fails is dropped: logging never refuses a command.
    class EventTap
      # The world verb that switches the tap on.
      VERB = "event_log"

      # Bytes after which the log moves to `<path>.1` and starts again.
      DEFAULT_MAX_BYTES = 5_000_000

      # Switches the tap on for a registry whose Hecks world declares it.
      #
      # @param registry [Runtime::Registry] the registry whose events and reactions are tapped
      # @return [EventTap, nil] the tap, nil when no world asks for one
      def self.install(registry)
        settings = registry.world("Hecks")&.for_verb(VERB)
        return nil if settings.to_h.empty? || settings[:path].to_s.empty?

        tap = new(path: settings[:path], max_bytes: settings.fetch(:max_bytes, DEFAULT_MAX_BYTES))
        registry.event_log.observer = tap.method(:event)
        registry.event_log.reaction_observer = tap.method(:reaction)
        tap
      end

      # @param path [String] the log file; `~` is the home directory
      # @param max_bytes [Integer] the size at which the log rotates
      def initialize(path:, max_bytes: DEFAULT_MAX_BYTES)
        @path = File.expand_path(path.to_s)
        @max_bytes = max_bytes.to_i
        @lock = Mutex.new
      end

      # Appends one line for an emitted event.
      #
      # @param event [Runtime::Event] the event
      # @return [void]
      def event(event)
        write("kind" => "event", "at" => event.occurred_at, "aggregate" => event.aggregate,
              "id" => event.id.to_s, "event" => event.name)
      end

      # Appends one line for a policy delivery: which policy reacted to which event, the command it
      # reached and what became of the delivery.
      #
      # @param record [Hash{Symbol => Object}] the reaction's outcome
      # @param identity [String, Integer, nil] the identity of the event instance it answered
      # @return [void]
      def reaction(record, identity)
        write("kind" => "reaction", "at" => Event.stamp, "id" => identity.to_s, "event" => record[:on].to_s,
              "policy" => record[:policy].to_s, "command" => record[:trigger].to_s, "outcome" => outcome(record))
      end

      private

      def outcome(record)
        return "delivered" if record[:delivered]

        "refused: #{record[:reason].to_s.slice(0, 160)}"
      end

      def write(line)
        @lock.synchronize do
          FileUtils.mkdir_p(File.dirname(@path))
          rotate
          File.open(@path, "a") { |file| file.puts(JSON.generate(line)) }
        end
      rescue SystemCallError, IOError
        nil
      end

      def rotate
        File.rename(@path, "#{@path}.1") if File.exist?(@path) && File.size(@path) >= @max_bytes
      end
    end
  end
end
