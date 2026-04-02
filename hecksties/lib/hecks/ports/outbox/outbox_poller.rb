# Hecks::Outbox::OutboxPoller
#
# Synchronous poller that reads unpublished entries from the outbox and
# publishes them to the event bus. After successful publication, each entry
# is marked as published so it will not be delivered again.
#
# In the memory adapter this runs synchronously in the same process.
# Production adapters can run the poller in a background thread or
# separate process against a shared database outbox table.
#
# Accepts an optional +publisher+ callable. When the event bus's publish
# method has been wrapped (e.g., to redirect into the outbox), the publisher
# bypasses the wrapper and delivers events to the original listeners.
#
# == Usage
#
#   poller = Hecks::Outbox::OutboxPoller.new(outbox, event_bus)
#   poller.drain    # publishes all pending entries
#   poller.stats    # => { published: 3, pending: 0 }
#
module Hecks
  module Outbox
    class OutboxPoller
      # @return [Object] the outbox to poll from (responds to poll, mark_published)
      attr_reader :outbox

      # @return [Hecks::EventBus] the event bus reference
      attr_reader :event_bus

      # Creates a new poller wired to an outbox and event bus.
      #
      # @param outbox [Hecks::Outbox::MemoryOutbox] the outbox to poll
      # @param event_bus [Hecks::EventBus] the event bus to publish to
      # @param publisher [#call, nil] optional callable for delivering events;
      #   defaults to event_bus.method(:publish) if not provided
      def initialize(outbox, event_bus, publisher: nil)
        @outbox = outbox
        @event_bus = event_bus
        @publisher = publisher || event_bus.method(:publish)
        @published_count = 0
      end

      # Polls the outbox and publishes all pending entries to the event bus.
      # Each entry is marked as published after successful delivery.
      #
      # @param limit [Integer] maximum entries to process per drain (default: 100)
      # @return [Integer] the number of entries published in this drain
      def drain(limit: 100)
        entries = @outbox.poll(limit: limit)
        entries.each do |entry|
          @publisher.call(entry[:event])
          @outbox.mark_published(entry[:id])
          @published_count += 1
        end
        entries.size
      end

      # Returns stats about the poller's lifetime activity.
      #
      # @return [Hash] with :published (total ever published) and :pending counts
      def stats
        { published: @published_count, pending: @outbox.pending_count }
      end
    end
  end
end
