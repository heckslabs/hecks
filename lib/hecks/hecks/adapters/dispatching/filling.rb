# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Whether a confirmed filling is running on this thread.
      #
      # A step of a filling dispatches in this process, so the reactions it owes run inside the
      # filling. One of them may ask for a roll; a roll that began while another filling is under
      # way would start the same work items twice, so it is refused and the next trigger finds
      # whatever capacity is left.
      module Filling
        # @return [Boolean] whether a confirmed filling is running on this thread
        def self.running? = Thread.current[:hecks_dispatch_filling] == true

        # Runs the block, marking it a filling when it is a confirmed one.
        #
        # @param confirmed [Boolean] whether the filling starts sessions
        # @yield the filling's work
        # @return [Object] what the block answers
        def self.during(confirmed)
          previous = Thread.current[:hecks_dispatch_filling]
          Thread.current[:hecks_dispatch_filling] = true if confirmed
          yield
        ensure
          Thread.current[:hecks_dispatch_filling] = previous
        end
      end
    end
  end
end
