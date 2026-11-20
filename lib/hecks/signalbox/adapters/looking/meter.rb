# frozen_string_literal: true

require "hecks/roundhouse/adapters/metering"

module Hecks
  module Adapters
    class Looking
      # Where a beat's look reads the machine: the meter the caller hands in for the beats it begins
      # on this thread, else Roundhouse's meter over the registry the look is given. A Signalbox
      # booted standing alone holds no AgentRun ledger, so its own meter cannot tell a coder from a
      # helper and meters no coder's draw; a caller that holds the ledger hands in its meter.
      module Meter
        # The thread variable that holds the handed-in meter.
        KEY = :hecks_signalbox_looking_meter

        module_function

        # @param meter [#call, nil] answers the machine facts as {Metering#machine_facts} does; nil
        #   leaves the look's own meter in charge
        # @yield the beats begun with that meter
        # @return [Object] what the block returns
        def handing(meter)
          previous = Thread.current.thread_variable_get(KEY)
          Thread.current.thread_variable_set(KEY, meter)
          yield
        ensure
          Thread.current.thread_variable_set(KEY, previous)
        end

        # @param registry [Runtime::Registry, nil] the registry the look is given
        # @return [Hash] the machine facts: the handed-in meter's, else Roundhouse's over `registry`
        def read(registry)
          handed = Thread.current.thread_variable_get(KEY)
          handed ? handed.call : Metering.new(registry: registry).machine_facts
        end
      end
    end
  end
end
