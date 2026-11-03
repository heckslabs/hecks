# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "event"
require_relative "value"

module Hecks
  module Runtime
    # An opt-in, append-only local log of what the runtime dispatched: one JSON line per event and
    # one per policy delivery. It exists for the domains that persist nothing (Memory keeps no
    # journal), so the PipelineBoard, or a `Follow` query in another process, can still see them.
    #
    # It is off unless a world declares it: `event_log "EventTap", path: "...", max_bytes: N`; a
    # client's world declares nothing, so a client writes no file. The boot may hand in an
    # override for a process no hecks command runs (a spec run and its children): a path replaces
    # the world's, an empty value switches the tap off. The log holds names, identities and
    # outcomes; a payload is written only for the aggregates the world lists under `payloads`
    # (the red flag's, so a subscriber learns the flag, commit, run and jobs from the event). A
    # write that fails is dropped: logging never refuses a command.
    class EventTap
      # The world verb that switches the tap on.
      VERB = "event_log"

      # Bytes after which the log moves to `<path>.1` and starts again.
      DEFAULT_MAX_BYTES = 5_000_000

      # Switches the tap on for a registry whose Hecks world declares it.
      #
      # @param registry [Runtime::Registry] the registry whose events and reactions are tapped
      # @param override [String, nil] a path in place of the world's; empty switches the tap off
      # @return [EventTap, nil] the tap, nil when no world asks for one
      def self.install(registry, override: nil)
        tap = declared(registry, override: override)
        return nil unless tap

        registry.event_log.observer = tap.method(:event)
        registry.event_log.reaction_observer = tap.method(:reaction)
        tap
      end

      # The tap a registry's Hecks world declares, not installed: a reader asks it where the log is.
      #
      # @param registry [Runtime::Registry] the registry whose world is read
      # @param override [String, nil] a path in place of the world's; empty means no tap
      # @return [EventTap, nil] the tap, nil when no world asks for one
      def self.declared(registry, override: nil)
        settings = registry.world("Hecks")&.for_verb(VERB).to_h
        path = path_for(settings, override)
        return nil unless path

        new(path: path, max_bytes: settings.fetch(:max_bytes, DEFAULT_MAX_BYTES), payloads: settings.fetch(:payloads, []))
      end

      # Where a world's tap writes: the override when one is given, else the world's path.
      #
      # @param settings [Hash] the Hecks world's `event_log` settings
      # @param override [String, nil] a path in place of the world's; empty switches the tap off
      # @return [String, nil] the log file; nil for no declared tap or an empty override
      def self.path_for(settings, override = nil)
        return nil if settings.to_h[:path].to_s.empty?

        path = override.nil? ? settings[:path] : override
        path.to_s.empty? ? nil : path
      end

      # @return [String] the log file
      attr_reader :path

      # @param path [String] the log file; `~` is the home directory
      # @param max_bytes [Integer] the size at which the log rotates
      # @param payloads [Array<String>] the aggregates, by bare name, whose events carry a payload
      def initialize(path:, max_bytes: DEFAULT_MAX_BYTES, payloads: [])
        @path = File.expand_path(path.to_s)
        @max_bytes = max_bytes.to_i
        @payloads = Array(payloads).map(&:to_s)
        @lock = Mutex.new
      end

      # Appends one line for an emitted event.
      #
      # @param event [Runtime::Event] the event
      # @return [void]
      def event(event)
        line = { "kind" => "event", "at" => event.occurred_at, "aggregate" => event.aggregate,
                 "id" => event.id.to_s, "event" => event.name }
        line["payload"] = plain(event.payload) if carries_payload?(event.aggregate)
        write(line)
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

      def carries_payload?(aggregate) = @payloads.include?(aggregate.to_s.split("::").last)

      # The payload as plain JSON data: value objects become their attribute hashes.
      def plain(payload) = JSON.parse(JSON.generate(Value.materialize(payload)))

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
