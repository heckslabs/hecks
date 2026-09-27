module Hecks
  module Runtime
    # A boot's own set of phase-tagged, conditionally-present gates (ADR 0031).
    # A gate is anything responding to `.call(registry, directory)`; run in registration order.
    #
    # Instance-scoped, one per `Loader.boot`, so one boot's gates never leak into the next.
    class BootGates
      # @return [void]
      def initialize
        @gates = Hash.new { |h, k| h[k] = [] }
      end

      # Adds a gate to `phase`, run in registration order alongside any other gate there.
      #
      # @param name [Symbol] the gate's name, checked by `registered?`
      # @param gate [Proc, Method] the gate; called as `gate.call(registry, directory)`
      # @param phase [Symbol] the phase this gate runs under, such as `:pre_verify` or
      #   `:post_verify`
      # @return [Hecks::Runtime::BootGates] self, for chaining
      def register(name, gate, phase:)
        @gates[phase] << [name, gate]
        self
      end

      # Reports whether a gate named `name` has been registered, under any phase.
      #
      # @param name [Symbol] the gate name to look for, across every phase
      # @return [Boolean] true if a gate named `name` was registered under any phase
      def registered?(name)
        @gates.values.flatten(1).any? { |registered_name, _gate| registered_name == name }
      end

      # Runs every gate registered under `phase`, in registration order.
      #
      # @param phase [Symbol] the phase to run, such as `:pre_verify` or `:post_verify`
      # @param registry [Runtime::Registry] the booted registry, passed to each gate
      # @param directory [String] the boot directory, passed to each gate
      # @return [void]
      def run!(phase, registry, directory)
        @gates[phase].each { |pair| pair.last.call(registry, directory) }
      end
    end
  end
end
