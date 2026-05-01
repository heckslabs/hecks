# Hecks::EventSourcing::OutboxPoller
#
# Polls the outbox for unpublished events and publishes them on the
# event bus, marking each as published. Provides both a one-shot
# `poll_once` for testing and a `start` method for production use.
#
# == Usage
#
#   poller = OutboxPoller.new(outbox, event_bus)
#   poller.poll_once   # publishes all pending, returns count
#
#   # In production (runs in a thread):
#   poller.start(interval: 0.5)
#   poller.stop
#
class Hecks::EventSourcing::OutboxPoller
  # @param outbox [Hecks::EventSourcing::Outbox] the outbox to poll
  # @param event_bus [Hecks::EventBus] the bus to publish events on
  def initialize(outbox, event_bus)
    @outbox = outbox
    @event_bus = event_bus
    @running = false
  end

  # Poll once: publish all pending events and mark them published.
  #
  # @return [Integer] the number of events published
  def poll_once
    pending = @outbox.pending
    pending.each do |entry|
      @event_bus.publish(entry.event)
      @outbox.mark_published(entry.id)
    end
    pending.size
  end

  # Start polling in a background thread.
  #
  # @param interval [Float] seconds between polls (default 1.0)
  # @return [Thread] the polling thread
  def start(interval: 1.0)
    @running = true
    @thread = Thread.new do
      while @running
        poll_once
        sleep(interval)
      end
    end
    @thread
  end

  # Stop the background polling thread.
  #
  # @return [void]
  def stop
    @running = false
    @thread&.join(2)
  end
end
