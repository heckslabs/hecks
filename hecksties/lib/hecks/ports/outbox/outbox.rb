# Hecks::Outbox
#
# Port interface for the transactional outbox pattern. Events are stored
# in a local outbox table (same transaction as the aggregate write) and
# later polled and published to the event bus. This guarantees at-least-once
# delivery even when the event bus or downstream consumers are unavailable.
#
# The outbox stores event entries with :id, :event, :stored_at, and
# :published flags. The poller calls +poll+ to retrieve unpublished
# entries and +mark_published+ to flag them after successful bus delivery.
#
# == Usage
#
#   outbox = Hecks::Outbox::MemoryOutbox.new
#   outbox.store(my_event)
#   outbox.poll.each do |entry|
#     bus.publish(entry[:event])
#     outbox.mark_published(entry[:id])
#   end
#
module Hecks
  # Hecks::Outbox
  #
  # Port interface for the transactional outbox pattern guaranteeing at-least-once event delivery.
  #
  module Outbox
    autoload :MemoryOutbox,  "hecks/ports/outbox/memory_outbox"
    autoload :OutboxPoller,  "hecks/ports/outbox/outbox_poller"
  end
end
