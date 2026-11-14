# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "event"
require_relative "event_tap/rotation"

module Hecks
  module Runtime
    # An opt-in, append-only local log of what the runtime dispatched: one JSON line per event and
    # one per policy delivery. It exists for the domains that persist nothing (Memory keeps no
    # journal), so a reader such as the PipelineBoard can still see them.
    #
    # It is off unless a world declares it: `event_log "EventTap", path: "...", max_bytes: N`. A
    # client's world declares nothing, so a client writes no file. The boot may hand in an
    # override for a process no hecks command runs (a spec run, and the children it starts): a
    # path replaces the world's, and an empty value switches the tap off, so a spec never writes
    # the owner's log. The log holds names, identities and outcomes, the few link keys of `LINKS`
    # (short identifiers that tie one record to another) and nothing else of a payload. A write
    # that fails is dropped: logging never refuses a command.
    # A generation past the last numbered file is kept in the {Archive} for `keep_hours`.
    class EventTap
      # The world verb that switches the tap on.
      VERB = "event_log"

      # Bytes after which the log moves to `<path>.1`; older generations shift up one number.
      DEFAULT_MAX_BYTES = 5_000_000

      # Rotated generations kept as plain text beside the live log. The oldest past this count is
      # archived.
      KEPT = 5

      # Hours an archived generation is kept: `keep_hours` of the world's `event_log`.
      DEFAULT_KEEP_HOURS = 48

      # The most bytes the archive holds, whatever its age: `archive_max_bytes` of the `event_log`.
      DEFAULT_ARCHIVE_MAX_BYTES = 200_000_000

      # The `event_log` settings a tap is built from, besides its path.
      LIMITS = { max_bytes: DEFAULT_MAX_BYTES, keep_hours: DEFAULT_KEEP_HOURS,
                 archive_max_bytes: DEFAULT_ARCHIVE_MAX_BYTES }.freeze

      # Payload keys that tie one record to another: a landed or pushed sha, a branch, a Work item's
      # slug. Only these payload values reach the log.
      LINKS = %w[branch landed boarded pushed commit ci_run work].freeze

      # Characters kept of one link value; a longer value is cut.
      LINK_WIDTH = 80

      # Bytes read from the end of a file to find its last line's sequence number.
      TAIL_BYTES = 65_536

      # Switches the tap on for a registry whose Hecks world declares it.
      #
      # @param registry [Runtime::Registry] the registry whose events and reactions are tapped
      # @param override [String, nil] a path in place of the world's; empty switches the tap off
      # @return [EventTap, nil] the tap, nil when no world asks for one
      def self.install(registry, override: nil)
        settings = registry.world("Hecks")&.for_verb(VERB).to_h
        path = path_for(settings, override)
        return nil unless path

        tap = new(path: path, **LIMITS.merge(settings.slice(*LIMITS.keys)))
        registry.event_log.observer = tap.method(:event)
        registry.event_log.reaction_observer = tap.method(:reaction)
        tap
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

      # @param path [String] the log file; `~` is the home directory
      # @param max_bytes [Integer] the size at which the log rotates
      # @param keep_hours [Numeric] hours an archived generation is kept
      # @param archive_max_bytes [Integer] the most bytes the archive holds
      def initialize(path:, max_bytes: DEFAULT_MAX_BYTES, keep_hours: DEFAULT_KEEP_HOURS,
                     archive_max_bytes: DEFAULT_ARCHIVE_MAX_BYTES)
        @path = File.expand_path(path.to_s)
        @archive = Archive.new(@path, keep_hours: keep_hours, max_bytes: archive_max_bytes)
        @rotation = Rotation.new(@path, max_bytes: max_bytes.to_i, kept: KEPT, archive: @archive)
        @lock = Mutex.new
      end

      # @return [Archive] the compressed generations older than the numbered files
      attr_reader :archive

      # Appends one line for an emitted event.
      #
      # @param event [Runtime::Event] the event
      # @return [void]
      def event(event)
        write("kind" => "event", "at" => event.occurred_at, "aggregate" => event.aggregate,
              "id" => event.id.to_s, "event" => event.name, "correlation" => correlation_of(event),
              "links" => links_of(event.payload))
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

      # The saga correlation of an event, its keys and values as short text.
      def correlation_of(event)
        (event.correlation || {}).to_h.to_h { |key, value| [key.to_s, link_text(value)] }
      end

      # The link keys of a payload, each value short and redacted; any other key is dropped.
      def links_of(payload)
        held = (payload || {}).to_h.transform_keys(&:to_sym)
        LINKS.each_with_object({}) do |key, links|
          text = held.key?(key.to_sym) ? link_text(held[key.to_sym]) : ""
          links[key] = text unless text.empty?
        end
      end

      # A payload value, plain, wrapped as `{value: ...}` or a built one-field value object, as text
      # of at most `LINK_WIDTH` chars. A value object of several fields is no link: it writes none.
      def link_text(value)
        text = value.is_a?(Hash) ? value.transform_keys(&:to_sym)[:value] : Value.scalar(value)
        Secrets.redact(text.to_s)[0, LINK_WIDTH]
      rescue TypeMismatch
        ""
      end

      def outcome(record)
        return "delivered" if record[:delivered]

        "refused: #{record[:reason].to_s.slice(0, 160)}"
      end

      # Appends one numbered line. A lock file serializes the processes that share the log, so each
      # sequence number follows the last one written, across rotations and restarts.
      def write(line)
        @lock.synchronize do
          FileUtils.mkdir_p(File.dirname(@path))
          File.open("#{@path}.lock", File::RDWR | File::CREAT) do |lock|
            lock.flock(File::LOCK_EX)
            @rotation.call
            File.open(@path, "a") { |file| file.puts(JSON.generate(line.merge("seq" => next_seq))) }
          end
        end
      rescue SystemCallError, IOError
        nil
      end

      def next_seq = (last_seq || 0) + 1

      # The sequence number of the newest line, from the live log or, just after a rotation, the
      # generation it moved to.
      def last_seq
        [@path, "#{@path}.1"].each do |file|
          seq = seq_at_end(file)
          return seq if seq
        end
        nil
      end

      def seq_at_end(file)
        return nil unless File.file?(file)

        line = last_line(file)
        line && JSON.parse(line)["seq"]
      rescue JSON::ParserError
        nil
      end

      # The tail is read as bytes: the seek can land inside a multi-byte character, which only
      # spoils the first, partial line, never the last one.
      def last_line(file)
        tail = File.open(file, "rb") { |io| io.seek([io.size - TAIL_BYTES, 0].max) && io.read }
        complete_last_line(tail)
      end

      def complete_last_line(bytes)
        line = bytes.split("\n".b).last
        line&.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
