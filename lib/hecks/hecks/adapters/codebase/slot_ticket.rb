# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      # How a waiting ticket is named and ranked in {SlotQueue}.
      #
      # A name is `<priority>-<arrival ns>-<pid>`, fixed width. The line is ordered by rank, then
      # arrival, then pid; the rank is the priority digit except for a landing's ticket
      # ({SlotQueue::LANDING}), which ranks as an ordinary one until it has waited `landing_age`
      # seconds and then ahead of every ordinary one and behind the train's and urgent ones.
      module SlotTicket
        # The rank of a landing's ticket that has aged: between urgent and ordinary.
        AGED_LANDING = 1.5

        # @return [String] the ticket name of a waiter
        def self.name(priority, arrival, pid)
          format("%<priority>d-%<ns>020d-%<pid>010d", priority: priority, ns: arrival, pid: pid)
        end

        # @param name [String] a ticket name
        # @param now [Integer] the time in nanoseconds
        # @param landing_age [Numeric] seconds a landing waits before it passes ordinary jobs
        # @return [Array] the key the line is sorted by
        def self.key(name, now, landing_age)
          priority, arrival, pid = name.split("-").map(&:to_i)
          [rank(priority, now - arrival, landing_age), arrival, pid]
        end

        # @return [Numeric] the rank of a ticket of this priority that has waited `waited` ns
        def self.rank(priority, waited, landing_age)
          return priority unless priority == SlotQueue::LANDING

          waited >= landing_age * 1_000_000_000 ? AGED_LANDING : SlotQueue::ORDINARY
        end
      end
    end
  end
end
