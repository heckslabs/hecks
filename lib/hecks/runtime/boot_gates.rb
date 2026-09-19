module Hecks
  module Runtime
    # A boot's own small set of phase-tagged, conditionally-present gates —
    # ADR 0031. Registration is instance-scoped, one per `Loader.boot`
    # call, never a module-level singleton: a process that boots more than
    # one registry in its lifetime (every spec suite does) must never let
    # one boot's capability profile leak into the next boot's gate list.
    #
    # A gate is anything `.call(registry, directory)`-able — an existing
    # module method handed over as a `Method` object (`EraCheck.method
    # (:check_lineage!)`) needs no wrapper; a bare block does. Phases run
    # in the order `run!` is called, gates within a phase in registration
    # order — today exactly one gate per phase, so ordering among
    # same-phase gates has never been exercised.
    #
    # This is deliberately not the same registry `Hecks::Projector` uses
    # (ADR 0027) — that one is a process-wide, static IR-in/artifact-out
    # registry with no bindings and no live-state mutation; this one is
    # per-boot and gates real I/O (a Postgres mint, a saga-store read).
    # Sharing a primitive between them is deferred until a third consumer
    # actually wants it (0031's own Rejected Alternatives).
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
