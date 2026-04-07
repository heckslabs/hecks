# Hecks::EventSourcing::Outbox
#
# In-memory outbox for transactional event publishing. Events are stored
# in the outbox atomically with the command, then published asynchronously
# by the OutboxPoller. Guarantees at-least-once delivery.
#
# == Usage
#
#   outbox = Outbox.new
#   outbox.store(event)
#   outbox.pending          # => [entry, ...]
#   outbox.mark_published(entry.id)
#   outbox.published        # => [entry, ...]
#
class Hecks::EventSourcing::Outbox
  # Hecks::EventSourcing::Outbox::Entry
  #
  # Immutable record representing a pending event in the transactional outbox.
  #
  Entry = Struct.new(:id, :event, :stored_at, :published, keyword_init: true)

  # @return [Array<Entry>] all outbox entries
  attr_reader :entries

  def initialize
    @entries = []
    @next_id = 0
    @mutex = Mutex.new
  end

  # Store an event in the outbox for later publishing.
  #
  # @param event [Object] the domain event
  # @return [Entry] the outbox entry
  def store(event)
    @mutex.synchronize do
      @next_id += 1
      entry = Entry.new(id: @next_id, event: event, stored_at: Time.now, published: false)
      @entries << entry
      entry
    end
  end

  # Return all unpublished entries in order.
  #
  # @return [Array<Entry>]
  def pending
    @mutex.synchronize { @entries.reject(&:published).dup }
  end

  # Mark an entry as published.
  #
  # @param id [Integer] the entry ID
  # @return [void]
  def mark_published(id)
    @mutex.synchronize do
      entry = @entries.find { |e| e.id == id }
      entry.published = true if entry
    end
  end

  # Return all published entries.
  #
  # @return [Array<Entry>]
  def published
    @mutex.synchronize { @entries.select(&:published).dup }
  end

  # Remove all entries. For testing only.
  #
  # @return [void]
  def clear
    @mutex.synchronize { @entries.clear }
  end
end
