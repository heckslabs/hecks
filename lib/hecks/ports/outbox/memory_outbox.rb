# Hecks::Outbox::MemoryOutbox
#
# In-memory implementation of the outbox port. Stores event entries in an
# array, suitable for development and testing. Production adapters would
# use a database table within the same transaction as the aggregate write.
#
# Each entry is a Hash with :id, :event, :stored_at, and :published keys.
# The +poll+ method returns unpublished entries in insertion order.
# The +mark_published+ method flags an entry so it is excluded from future polls.
#
# == Usage
#
#   outbox = Hecks::Outbox::MemoryOutbox.new
#   outbox.store(pizza_created_event)
#   outbox.poll          # => [{ id: "abc...", event: ..., stored_at: ..., published: false }]
#   outbox.mark_published("abc...")
#   outbox.poll          # => []
#   outbox.entries.size  # => 1
#
require "securerandom"

module Hecks
  module Outbox
    # Hecks::Outbox::MemoryOutbox
    #
    # In-memory implementation of the outbox port suitable for development and testing.
    #
    class MemoryOutbox
      # @return [Array<Hash>] all stored outbox entries
      attr_reader :entries

      # Creates a new empty in-memory outbox.
      def initialize
        @entries = []
      end

      # Stores an event in the outbox for later publishing.
      #
      # @param event [Object] the domain event to store
      # @return [Hash] the created outbox entry
      def store(event)
        entry = {
          id: SecureRandom.uuid,
          event: event,
          stored_at: Time.now,
          published: false
        }
        @entries << entry
        entry
      end

      # Returns all unpublished entries in insertion order.
      #
      # @param limit [Integer] maximum entries to return (default: 100)
      # @return [Array<Hash>] unpublished outbox entries
      def poll(limit: 100)
        @entries.select { |e| !e[:published] }.first(limit)
      end

      # Marks an outbox entry as published so it is excluded from future polls.
      #
      # @param entry_id [String] the UUID of the entry to mark
      # @return [Boolean] true if the entry was found and marked, false otherwise
      def mark_published(entry_id)
        entry = @entries.find { |e| e[:id] == entry_id }
        return false unless entry
        entry[:published] = true
        true
      end

      # Returns the count of unpublished entries.
      #
      # @return [Integer]
      def pending_count
        @entries.count { |e| !e[:published] }
      end

      # Clears all entries from the outbox.
      #
      # @return [void]
      def clear
        @entries.clear
      end
    end
  end
end
